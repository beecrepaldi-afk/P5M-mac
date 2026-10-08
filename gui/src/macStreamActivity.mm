#include "macStreamActivity.h"

#include <QWindow>
#include <QString>
#include <SystemConfiguration/SystemConfiguration.h>

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

#include <chiaki/thread.h>
#include <pthread/qos.h>

static id<NSObject> stream_activity = nil;

void setMacStreamActivity(bool active)
{
	if (active == (stream_activity != nil))
		return;
	if (active)
	{
		stream_activity = [[NSProcessInfo processInfo]
			beginActivityWithOptions:NSActivityUserInitiated | NSActivityLatencyCritical | NSActivityIdleDisplaySleepDisabled
			reason:@"Remote Play session"];
		[stream_activity retain];
		NSLog(@"chiaki-ng: stream activity started (display sleep, App Nap and timer coalescing disabled)");
	}
	else
	{
		[[NSProcessInfo processInfo] endActivity:stream_activity];
		[stream_activity release];
		stream_activity = nil;
		NSLog(@"chiaki-ng: stream activity ended");
	}
}

void setCurrentThreadUserInteractive()
{
	pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
}

static void streamThreadQos(ChiakiThreadName name, void *)
{
	switch (name)
	{
		case CHIAKI_THREAD_NAME_TAKION:
		case CHIAKI_THREAD_NAME_TAKION_SEND:
		case CHIAKI_THREAD_NAME_FEEDBACK:
		case CHIAKI_THREAD_NAME_CTRL:
		case CHIAKI_THREAD_NAME_CONGESTION:
			setCurrentThreadUserInteractive();
			break;
		default:
			break;
	}
}

void installMacStreamThreadQos()
{
	chiaki_thread_set_affinity_cb(streamThreadQos, nullptr);
}

void installMacFullscreenAutoHide()
{
	NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
	[center addObserverForName:NSWindowDidEnterFullScreenNotification object:nil queue:[NSOperationQueue mainQueue]
	                usingBlock:^(NSNotification *note) {
		NSApp.presentationOptions = NSApplicationPresentationFullScreen
		                          | NSApplicationPresentationAutoHideMenuBar
		                          | NSApplicationPresentationAutoHideDock;
		NSWindow *window = note.object;
        // A geometria do fullscreen nativo pertence ao AppKit. Forçar screen.frame
        // depois da transição pode tirar a janela das condições de scanout direto.
        NSLog(@"chiaki-ng: native fullscreen entered; AppKit geometry, menu bar and Dock auto-hidden");
	}];
	[center addObserverForName:NSWindowWillExitFullScreenNotification object:nil queue:[NSOperationQueue mainQueue]
	                usingBlock:^(NSNotification *) {
		NSApp.presentationOptions = NSApplicationPresentationDefault;
	}];
}

double macWindowHiddenTop(QWindow *qwindow)
{
	NSView *view = reinterpret_cast<NSView *>(qwindow->winId());
	NSWindow *window = view.window;
	NSScreen *screen = window.screen;
	if (!window || !screen || !(window.styleMask & NSWindowStyleMaskFullScreen))
		return 0;
    // Só reserva a faixa se o AppKit realmente incluiu essa área na janela.
    // Na geometria nativa abaixo da câmera não subtrai o inset duas vezes.
	if (window.frame.size.height < screen.frame.size.height - 0.5)
		return 0;
	return screen.safeAreaInsets.top;
}

bool setMacBorderlessFullscreen(QWindow *qwindow, bool on)
{
	static bool active = false;
	static NSRect saved_frame;
	static NSWindowStyleMask saved_mask = 0;
	static id resize_observer = nil;
	NSView *view = reinterpret_cast<NSView *>(qwindow->winId());
	NSWindow *window = view.window;
	if (!window)
		return false;
	if (on == active)
		return true;
	if (on && (window.styleMask & NSWindowStyleMaskFullScreen)) {
		// Leave the native fullscreen Space first: borderless on top of it
		// breaks the geometry.
		__block id observer = [[NSNotificationCenter defaultCenter]
			addObserverForName:NSWindowDidExitFullScreenNotification object:window queue:[NSOperationQueue mainQueue]
			usingBlock:^(NSNotification *) {
				[[NSNotificationCenter defaultCenter] removeObserver:observer];
				setMacBorderlessFullscreen(qwindow, true);
			}];
		[window toggleFullScreen:nil];
		active = false;
		return true;
	}
	if (on) {
		NSScreen *screen = window.screen ?: NSScreen.mainScreen;
		saved_frame = window.frame;
		saved_mask = window.styleMask;
		NSApp.presentationOptions = NSApplicationPresentationHideDock | NSApplicationPresentationHideMenuBar;
		window.styleMask = NSWindowStyleMaskBorderless;
		[window setFrame:screen.frame display:YES];
		[window makeKeyAndOrderFront:nil];
		// AppKit (or Qt syncing its geometry) may pull the window back under
		// the menu bar strip: put it back over the whole panel.
		resize_observer = [[NSNotificationCenter defaultCenter]
			addObserverForName:NSWindowDidResizeNotification object:window queue:[NSOperationQueue mainQueue]
			usingBlock:^(NSNotification *) {
				NSScreen *s = window.screen ?: NSScreen.mainScreen;
				if (!active || NSEqualRects(window.frame, s.frame))
					return;
				NSLog(@"chiaki-ng: borderless fullscreen shrunk to %@, back to %@",
				      NSStringFromRect(window.frame), NSStringFromRect(s.frame));
				[window setFrame:s.frame display:YES];
			}];
		NSLog(@"chiaki-ng: borderless fullscreen %@ on %@ (notch inset %.0f)",
		      NSStringFromRect(window.frame), NSStringFromRect(screen.frame), screen.safeAreaInsets.top);
	} else {
		if (resize_observer) {
			[[NSNotificationCenter defaultCenter] removeObserver:resize_observer];
			resize_observer = nil;
		}
		window.styleMask = saved_mask;
		[window setFrame:saved_frame display:YES];
		NSApp.presentationOptions = NSApplicationPresentationDefault;
		[window makeKeyAndOrderFront:nil];
	}
	active = on;
	return true;
}

QString macNetworkKey()
{
	// macOS keeps a signature of the current network for the primary
	// service, with the router's hardware address in it
	// ("IPv4.Router=...;IPv4.RouterHardwareAddress=aa:bb:...").
	QString router, signature;
	SCDynamicStoreRef store = SCDynamicStoreCreate(nullptr, CFSTR("chiaki-ng"), nullptr, nullptr);
	if (!store)
		return QString();
	CFDictionaryRef global = (CFDictionaryRef)SCDynamicStoreCopyValue(store, CFSTR("State:/Network/Global/IPv4"));
	if (global) {
		CFStringRef r = (CFStringRef)CFDictionaryGetValue(global, CFSTR("Router"));
		if (r && CFGetTypeID(r) == CFStringGetTypeID())
			router = QString::fromCFString(r);
		CFStringRef service = (CFStringRef)CFDictionaryGetValue(global, CFSTR("PrimaryService"));
		if (service && CFGetTypeID(service) == CFStringGetTypeID()) {
			CFStringRef key = CFStringCreateWithFormat(nullptr, nullptr, CFSTR("State:/Network/Service/%@/IPv4"), service);
			CFDictionaryRef ipv4 = (CFDictionaryRef)SCDynamicStoreCopyValue(store, key);
			if (ipv4) {
				CFStringRef sig = (CFStringRef)CFDictionaryGetValue(ipv4, CFSTR("NetworkSignature"));
				if (sig && CFGetTypeID(sig) == CFStringGetTypeID())
					signature = QString::fromCFString(sig);
				CFRelease(ipv4);
			}
			CFRelease(key);
		}
		CFRelease(global);
	}
	CFRelease(store);
	const QString tag = QStringLiteral("RouterHardwareAddress=");
	const int at = signature.indexOf(tag);
	if (at >= 0) {
		const QString mac = signature.mid(at + tag.size()).section(QLatin1Char(';'), 0, 0).trimmed();
		if (!mac.isEmpty())
			return mac.toLower();
	}
	return router;
}
