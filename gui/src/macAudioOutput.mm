// SPDX-License-Identifier: AGPL-3.0-or-later
// Adaptador próprio sobre APIs públicas Apple. Referência de configuração:
// Twilight / Andy Grundman, app/streaming/audio/renderers/coreaudio.
#include "macAudioOutput.h"
#include "macAudioRing.h"
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <dispatch/dispatch.h>
#include <Block.h>
#include <atomic>
#include <cmath>
#include <cstring>
#include <vector>

namespace {
AudioObjectPropertyAddress address(AudioObjectPropertySelector selector, AudioObjectPropertyScope scope=kAudioObjectPropertyScopeGlobal) {
    return {selector,scope,kAudioObjectPropertyElementMain};
}
template<class T> bool get(AudioObjectID object, AudioObjectPropertySelector selector,T &value,AudioObjectPropertyScope scope=kAudioObjectPropertyScopeGlobal) {
    auto a=address(selector,scope); UInt32 size=sizeof(value);
    return AudioObjectGetPropertyData(object,&a,0,nullptr,&size,&value)==noErr;
}
std::string name(AudioDeviceID device) {
    CFStringRef text=nullptr;
    if(!get(device,kAudioObjectPropertyName,text)||!text) return {};
    char buffer[1024]{}; CFStringGetCString(text,buffer,sizeof(buffer),kCFStringEncodingUTF8); CFRelease(text); return buffer;
}
AudioStreamBasicDescription format(uint32_t rate,uint32_t channels) {
    AudioStreamBasicDescription f{}; f.mSampleRate=rate; f.mFormatID=kAudioFormatLinearPCM;
    f.mFormatFlags=kAudioFormatFlagIsFloat|kAudioFormatFlagsNativeEndian|kAudioFormatFlagIsPacked|kAudioFormatFlagIsNonInterleaved;
    f.mFramesPerPacket=1; f.mChannelsPerFrame=channels; f.mBitsPerChannel=32; f.mBytesPerFrame=4; f.mBytesPerPacket=4; return f;
}
}
struct MacAudioOutput::Impl {
    AudioUnit output=nullptr,mixer=nullptr;
    AudioDeviceID device=kAudioObjectUnknown;
    uint32_t rate=0,channels=0,outputChannels=0;
    MacAudioRing ring;
    std::shared_ptr<std::atomic<bool>> reopen=std::make_shared<std::atomic<bool>>(false);
    dispatch_queue_t listenerQueue=dispatch_queue_create("io.github.beecrepaldi-afk.p5m.audio-route",DISPATCH_QUEUE_SERIAL);
    AudioObjectPropertyListenerBlock listenerBlock=nullptr;
    std::vector<AudioObjectPropertyAddress> listeners;
    bool defaultListener=false;
    double latency=0;
    std::string info;
    static OSStatus input(void *context,AudioUnitRenderActionFlags *flags,const AudioTimeStamp*,UInt32,UInt32 frames,AudioBufferList *data) {
        auto &s=*static_cast<Impl*>(context);
        float *planes[8]{};
        if(data->mNumberBuffers!=s.channels) return kAudio_ParamError;
        for(uint32_t c=0;c<s.channels;++c) {
            if(!data->mBuffers[c].mData || data->mBuffers[c].mDataByteSize<frames*sizeof(float)) return kAudio_ParamError;
            planes[c]=static_cast<float*>(data->mBuffers[c].mData);
        }
        s.ring.pop(planes,frames);
        if(s.ring.renderedSilence()) *flags|=kAudioUnitRenderAction_OutputIsSilence;
        return noErr;
    }
    static OSStatus render(void *context,AudioUnitRenderActionFlags *flags,const AudioTimeStamp *time,UInt32 bus,UInt32 frames,AudioBufferList *data) {
        auto &s=*static_cast<Impl*>(context);
        if(s.mixer) {
            OSStatus status=AudioUnitRender(s.mixer,flags,time,0,frames,data);
            if(status!=noErr) {
                for(UInt32 c=0;c<data->mNumberBuffers;++c) if(data->mBuffers[c].mData) std::memset(data->mBuffers[c].mData,0,data->mBuffers[c].mDataByteSize);
                s.reopen->store(true,std::memory_order_release);
            }
            return status;
        }
        return input(context,flags,time,bus,frames,data);
    }
    ~Impl() {
        // Remover listeners antes de liberar o contexto; stop/join dos callbacks é do AU.
        if(defaultListener) {
            auto a=address(kAudioHardwarePropertyDefaultOutputDevice);
            AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject,&a,listenerQueue,listenerBlock);
        }
        for(auto &a:listeners) AudioObjectRemovePropertyListenerBlock(device,&a,listenerQueue,listenerBlock);
        // O bloco captura somente estado independente, nunca Impl/AudioUnit. Mesmo um
        // callback já enfileirado mantém sua atomic viva depois do fechamento.
        if(listenerBlock) Block_release(listenerBlock);
        if(listenerQueue) dispatch_release(listenerQueue);
        if(output) { AudioOutputUnitStop(output); AudioUnitUninitialize(output); AudioComponentInstanceDispose(output); }
        if(mixer) { AudioUnitUninitialize(mixer); AudioComponentInstanceDispose(mixer); }
    }
};
MacAudioOutput::MacAudioOutput()=default;
MacAudioOutput::~MacAudioOutput()=default;
void MacAudioOutput::close() { impl.reset(); }
bool MacAudioOutput::open(uint32_t rate,uint8_t channels,const std::string &deviceName,bool spatial,bool tracking,uint32_t targetMs,std::string &error,MacAudioLayout layout) {
    close(); error.clear();
    if(rate<8000||rate>192000||(channels!=1&&channels!=2&&channels!=6&&channels!=8)) { error="Unsupported PCM sample rate or channel count"; return false; }
    if(channels>2 && !((channels==6&&layout==MacAudioLayout::Wave51)||(channels==8&&layout==MacAudioLayout::Wave71))) {
        error="Multichannel PCM requires a verified channel order; the PS5 surround layout is not known"; return false;
    }
    auto s=std::make_unique<Impl>(); s->rate=rate; s->channels=channels;
    auto fail=[&](const char *stage,OSStatus status) { error=std::string(stage)+" (CoreAudio status "+std::to_string(status)+")"; return false; };
    if(!get(kAudioObjectSystemObject,kAudioHardwarePropertyDefaultOutputDevice,s->device)||s->device==kAudioObjectUnknown) return fail("No default audio output device",-1);
    if(!deviceName.empty()) {
        auto a=address(kAudioHardwarePropertyDevices); UInt32 size=0;
        OSStatus status=AudioObjectGetPropertyDataSize(kAudioObjectSystemObject,&a,0,nullptr,&size);
        if(status!=noErr) return fail("Cannot enumerate audio output devices",status);
        std::vector<AudioDeviceID> devices(size/sizeof(AudioDeviceID));
        status=AudioObjectGetPropertyData(kAudioObjectSystemObject,&a,0,nullptr,&size,devices.data());
        if(status!=noErr) return fail("Cannot read audio output devices",status);
        bool found=false;
        for(auto d:devices) if(name(d)==deviceName) { s->device=d; found=true; break; }
        if(!found) return fail("Selected audio output device is unavailable",-1);
    }
    UInt32 source=0,transport=0;
    get(s->device,kAudioDevicePropertyDataSource,source,kAudioDevicePropertyScopeOutput);
    get(s->device,kAudioDevicePropertyTransportType,transport);
    // USB e Bluetooth não provam que a saída seja um fone. Terminais desconhecidos ficam diretos.
    UInt32 kind=source=='ispk'?kSpatialMixerOutputType_BuiltInSpeakers:source=='hdpn'?kSpatialMixerOutputType_Headphones:kSpatialMixerOutputType_ExternalSpeakers;
    auto streamsAddress=address(kAudioDevicePropertyStreams,kAudioDevicePropertyScopeOutput); UInt32 streamBytes=0;
    if(AudioObjectGetPropertyDataSize(s->device,&streamsAddress,0,nullptr,&streamBytes)==noErr) {
        std::vector<AudioStreamID> streams(streamBytes/sizeof(AudioStreamID));
        if(AudioObjectGetPropertyData(s->device,&streamsAddress,0,nullptr,&streamBytes,streams.data())==noErr)
            for(auto stream:streams) { UInt32 terminal=0; if(get(stream,kAudioStreamPropertyTerminalType,terminal)&&terminal==kAudioStreamTerminalTypeHeadphones) kind=kSpatialMixerOutputType_Headphones; }
    }
    if(transport==kAudioDeviceTransportTypeHDMI||transport==kAudioDeviceTransportTypeDisplayPort) kind=kSpatialMixerOutputType_ExternalSpeakers;
    bool useSpatial=spatial&&channels>2&&kind!=kSpatialMixerOutputType_ExternalSpeakers;
    bool unknownRoute=kind==kSpatialMixerOutputType_ExternalSpeakers&&transport!=kAudioDeviceTransportTypeHDMI&&transport!=kAudioDeviceTransportTypeDisplayPort;
    s->outputChannels=useSpatial?2:channels;
    if(channels>2&&!useSpatial) {
        auto a=address(kAudioDevicePropertyStreamConfiguration,kAudioDevicePropertyScopeOutput);
        UInt32 bytes=0;
        if(AudioObjectGetPropertyDataSize(s->device,&a,0,nullptr,&bytes)!=noErr)
            return fail("Cannot verify multichannel output capacity",-1);
        std::vector<uint8_t> storage(bytes);
        if(AudioObjectGetPropertyData(s->device,&a,0,nullptr,&bytes,storage.data())!=noErr)
            return fail("Cannot read multichannel output capacity",-1);
        auto *buffers=reinterpret_cast<AudioBufferList*>(storage.data()); UInt32 available=0;
        for(UInt32 i=0;i<buffers->mNumberBuffers;++i) available+=buffers->mBuffers[i].mNumberChannels;
        if(available<channels) return fail("Selected output cannot carry the requested multichannel PCM layout",-1);
    }
    s->ring.enablePriming(true); s->ring.reset(rate/2,channels); s->ring.setTrimSlack(rate/50); s->ring.setFadeFrames(std::max<uint32_t>(1,rate/1000)); s->ring.setTarget(std::min<size_t>(rate/2,std::max<size_t>(1,rate*targetMs/1000)));
    AudioComponentDescription desc{kAudioUnitType_Output,kAudioUnitSubType_HALOutput,kAudioUnitManufacturer_Apple,0,0};
    AudioComponent component=AudioComponentFindNext(nullptr,&desc);
    if(!component) return fail("HAL output audio unit is unavailable",-1);
    OSStatus status=AudioComponentInstanceNew(component,&s->output);
    if(status!=noErr) return fail("Cannot create HAL output audio unit",status);
    auto set=[&](AudioUnit unit,AudioUnitPropertyID property,AudioUnitScope scope,UInt32 bus,const void *value,UInt32 size,const char *stage) {
        OSStatus result=AudioUnitSetProperty(unit,property,scope,bus,value,size); if(result!=noErr) error=std::string(stage)+" (CoreAudio status "+std::to_string(result)+")"; return result==noErr;
    };
    UInt32 zero=0,one=1,maxFrames=8192;
    if(!set(s->output,kAudioOutputUnitProperty_EnableIO,kAudioUnitScope_Input,1,&zero,4,"Cannot disable audio capture")||
       !set(s->output,kAudioOutputUnitProperty_EnableIO,kAudioUnitScope_Output,0,&one,4,"Cannot enable audio output")||
       !set(s->output,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&s->device,sizeof(s->device),"Cannot select audio device")) return false;
    AudioChannelLayout acl{};
    acl.mChannelLayoutTag=channels==1?kAudioChannelLayoutTag_Mono:channels==2?kAudioChannelLayoutTag_Stereo:channels==6?kAudioChannelLayoutTag_WAVE_5_1_A:kAudioChannelLayoutTag_WAVE_7_1;
    auto inputFormat=format(rate,channels),outputFormat=format(rate,s->outputChannels);
    if(useSpatial) {
        desc={kAudioUnitType_Mixer,kAudioUnitSubType_SpatialMixer,kAudioUnitManufacturer_Apple,0,0};
        component=AudioComponentFindNext(nullptr,&desc);
        if(!component) return fail("Apple SpatialMixer is unavailable",-1);
        status=AudioComponentInstanceNew(component,&s->mixer);
        if(status!=noErr) return fail("Cannot create Apple SpatialMixer",status);
        UInt32 algorithm=kSpatializationAlgorithm_UseOutputType,mode=kSpatialMixerSourceMode_AmbienceBed;
        AURenderCallbackStruct cb{Impl::input,s.get()};
        AudioChannelLayout stereo{}; stereo.mChannelLayoutTag=kAudioChannelLayoutTag_Stereo;
        if(!set(s->mixer,kAudioUnitProperty_ElementCount,kAudioUnitScope_Input,0,&one,4,"Cannot set spatial input bus")||
           !set(s->mixer,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Input,0,&inputFormat,sizeof(inputFormat),"Cannot set spatial input format")||
           !set(s->mixer,kAudioUnitProperty_AudioChannelLayout,kAudioUnitScope_Input,0,&acl,sizeof(acl),"Cannot set verified spatial input layout")||
           !set(s->mixer,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Output,0,&outputFormat,sizeof(outputFormat),"Cannot set spatial output format")||
           !set(s->mixer,kAudioUnitProperty_AudioChannelLayout,kAudioUnitScope_Output,0,&stereo,sizeof(stereo),"Cannot set spatial stereo layout")||
           !set(s->mixer,kAudioUnitProperty_SpatializationAlgorithm,kAudioUnitScope_Input,0,&algorithm,4,"Cannot configure spatial algorithm")||
           !set(s->mixer,kAudioUnitProperty_SpatialMixerSourceMode,kAudioUnitScope_Input,0,&mode,4,"Cannot configure spatial source mode")||
           !set(s->mixer,kAudioUnitProperty_SpatialMixerOutputType,kAudioUnitScope_Global,0,&kind,4,"Cannot configure spatial output type")||
           !set(s->mixer,kAudioUnitProperty_MaximumFramesPerSlice,kAudioUnitScope_Global,0,&maxFrames,4,"Cannot configure spatial slice size")||
           !set(s->mixer,kAudioUnitProperty_SetRenderCallback,kAudioUnitScope_Input,0,&cb,sizeof(cb),"Cannot configure spatial input callback")) return false;
        s->info=kind==kSpatialMixerOutputType_Headphones?"CoreAudio: surround rendered binaurally":"CoreAudio: surround rendered for built-in speakers";
        // Estas APIs são oportunistas: falha nunca derruba o som nem é sucesso presumido.
        if(@available(macOS 13.0,*)) {
            UInt32 hrtf=kSpatialMixerPersonalizedHRTFMode_Auto;
            AudioUnitSetProperty(s->mixer,kAudioUnitProperty_SpatialMixerPersonalizedHRTFMode,kAudioUnitScope_Global,0,&hrtf,4);
        }
        if(tracking&&kind==kSpatialMixerOutputType_Headphones) {
            if(@available(macOS 12.3,*)) {
                status=AudioUnitSetProperty(s->mixer,kAudioUnitProperty_SpatialMixerEnableHeadTracking,kAudioUnitScope_Global,0,&one,4);
                s->info+=status==noErr?"; head tracking requested (device support required)":"; head tracking unavailable (status "+std::to_string(status)+")";
            }
        }
        status=AudioUnitInitialize(s->mixer); if(status!=noErr) return fail("Cannot initialize Apple SpatialMixer",status);
        if(kind==kSpatialMixerOutputType_Headphones) {
            if(@available(macOS 14.0,*)) {
                UInt32 personalized=0,bytes=sizeof(personalized);
                if(AudioUnitGetProperty(s->mixer,kAudioUnitProperty_SpatialMixerAnyInputIsUsingPersonalizedHRTF,kAudioUnitScope_Global,0,&personalized,&bytes)==noErr)
                    s->info+=personalized?"; personalized HRTF active":"; generic HRTF";
            }
        }
        Float64 seconds=0; UInt32 bytes=sizeof(seconds);
        if(AudioUnitGetProperty(s->mixer,kAudioUnitProperty_Latency,kAudioUnitScope_Global,0,&seconds,&bytes)==noErr) s->latency+=seconds*1000;
    } else {
        s->info=channels<=2?"CoreAudio: stereo/mono PCM preserved; spatial mixer bypassed":"CoreAudio: direct multichannel PCM";
        if(unknownRoute) s->info+="; output type unverified, spatial rendering not assumed";
        if(tracking) s->info+="; head tracking inactive without surround spatial rendering";
    }
    AURenderCallbackStruct callback{Impl::render,s.get()};
    if(!set(s->output,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Input,0,&outputFormat,sizeof(outputFormat),"Cannot set HAL PCM format")||
       !set(s->output,kAudioUnitProperty_SetRenderCallback,kAudioUnitScope_Input,0,&callback,sizeof(callback),"Cannot set HAL callback")||
       !set(s->output,kAudioUnitProperty_MaximumFramesPerSlice,kAudioUnitScope_Global,0,&maxFrames,4,"Cannot configure HAL slice size")) return false;
    if(!useSpatial&&!set(s->output,kAudioUnitProperty_AudioChannelLayout,kAudioUnitScope_Input,0,&acl,sizeof(acl),"Cannot set direct PCM channel layout")) return false;
    status=AudioUnitInitialize(s->output); if(status!=noErr) return fail("Cannot initialize HAL output",status);
    Float64 hardwareRate=rate; get(s->device,kAudioDevicePropertyNominalSampleRate,hardwareRate);
    for(auto property:std::initializer_list<AudioObjectPropertySelector>{kAudioDevicePropertyLatency,kAudioDevicePropertySafetyOffset,kAudioDevicePropertyBufferFrameSize}) {
        UInt32 frames=0; if(get(s->device,property,frames,kAudioDevicePropertyScopeOutput)) s->latency+=frames*1000.0/hardwareRate;
    }
    auto routeState=s->reopen;
    s->listenerBlock=Block_copy(^(UInt32,const AudioObjectPropertyAddress*) {
        routeState->store(true,std::memory_order_release);
    });
    for(auto property:std::initializer_list<AudioObjectPropertySelector>{kAudioDevicePropertyDeviceIsAlive,kAudioDevicePropertyNominalSampleRate,kAudioDevicePropertyDataSource,kAudioDevicePropertyStreamConfiguration}) {
        auto a=address(property,property==kAudioDevicePropertyDataSource||property==kAudioDevicePropertyStreamConfiguration?kAudioDevicePropertyScopeOutput:kAudioObjectPropertyScopeGlobal);
        if(AudioObjectAddPropertyListenerBlock(s->device,&a,s->listenerQueue,s->listenerBlock)==noErr) s->listeners.push_back(a);
    }
    if(deviceName.empty()) {
        auto a=address(kAudioHardwarePropertyDefaultOutputDevice);
        s->defaultListener=AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject,&a,s->listenerQueue,s->listenerBlock)==noErr;
    }
    status=AudioOutputUnitStart(s->output); if(status!=noErr) return fail("Cannot start HAL output",status);
    impl=std::move(s); return true;
}
bool MacAudioOutput::queue(const int16_t *pcm,size_t frames) { return impl&&pcm&&impl->ring.push(pcm,frames); }
size_t MacAudioOutput::queuedBytes() const { return impl?impl->ring.queued()*impl->channels*sizeof(int16_t):0; }
void MacAudioOutput::setTargetMs(double ms) { if(impl&&std::isfinite(ms)) impl->ring.setTarget(size_t(std::clamp(ms,0.0,500.0)*impl->rate/1000)); }
void MacAudioOutput::clear() { if(impl) impl->ring.clear(); }
bool MacAudioOutput::isReady() const { return bool(impl); }
bool MacAudioOutput::needsReopen() const { return impl&&impl->reopen->load(std::memory_order_acquire); }
std::string MacAudioOutput::description() const { return impl?impl->info:"CoreAudio output is closed"; }
double MacAudioOutput::latencyMs() const { return impl?impl->latency:0; }
uint64_t MacAudioOutput::underruns() const { return impl?impl->ring.underruns():0; }

uint64_t MacAudioOutput::trimmedFrames() const { return impl?impl->ring.trimmedFrames():0; }
uint64_t MacAudioOutput::rebufferEvents() const { return impl?impl->ring.rebufferEvents():0; }
