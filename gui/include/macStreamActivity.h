#ifndef CHIAKI_MACSTREAMACTIVITY_H
#define CHIAKI_MACSTREAMACTIVITY_H

// While a stream session is open, tell macOS the app is doing latency-critical
// user-initiated work: keeps the display awake when the controller sits idle
// (cutscenes), and opts out of App Nap and timer coalescing.
void setMacStreamActivity(bool active);

// Marks the calling thread latency-critical (QoS user-interactive) so the
// scheduler keeps it on performance cores.
void setCurrentThreadUserInteractive();

// Registers the libchiaki thread hook: the stream threads (Takion receive,
// which also decodes the video, and the ones answering the console) become
// user-interactive as they start.
void installMacStreamThreadQos();

// While one of our windows is fullscreen, auto-hide the menu bar and the Dock
// even if the user keeps them visible in fullscreen (System Settings). The
// picture then owns the whole panel, with nothing for the compositor to layer
// on top of it.
void installMacFullscreenAutoHide();

// Logs who takes the focus away and what covers our window (diagnostics).

class QWindow;
class QString;

// Points at the top of the window that macOS hides in native fullscreen (the
// strip around the camera housing) while the window covers it; 0 otherwise.
double macWindowHiddenTop(QWindow *window);

// Fullscreen without a macOS fullscreen Space: a borderless window over the
// whole panel, menu bar and Dock hidden. The native fullscreen keeps the
// strip around the camera black; this one lets the picture use every pixel
// (zoom "Fill screen"), at the cost of compositing (~10 ms). Leaves a native
// fullscreen first when one is on. False when there is no native window yet.
bool setMacBorderlessFullscreen(QWindow *window, bool on);

// Identifies the network the Mac is on: the hardware address of the default
// router ("aa:bb:..."), or its IP when the address is unknown; empty offline.
QString macNetworkKey();

#endif // CHIAKI_MACSTREAMACTIVITY_H
