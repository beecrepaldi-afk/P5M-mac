#ifndef MACCONTROLLERGESTURES_H
#define MACCONTROLLERGESTURES_H

// Asks macOS not to run its own gestures on controller buttons (the PS/Home
// button opens the system game overlay since macOS 26) while chiaki-ng is the
// active app, so the press reaches the console. Covers controllers connected
// later too. Call once on the main thread after the application is created.
void disableControllerSystemGestures();

// P5M: hides the mouse cursor until the mouse moves again. Called on a
// controller press, so the pointer does not sit over the menus while playing
// from the couch. Main thread.
void hideCursorUntilMouseMoves();

#endif // MACCONTROLLERGESTURES_H
