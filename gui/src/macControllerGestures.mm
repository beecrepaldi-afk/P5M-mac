#include "macControllerGestures.h"

#import <AppKit/AppKit.h>
#import <GameController/GameController.h>

#include <QLoggingCategory>

Q_DECLARE_LOGGING_CATEGORY(chiakiGui);

static void disableGestures(GCController *controller)
{
	QStringList bound;
	for (GCControllerElement *element in controller.physicalInputProfile.allElements) {
		if (element.boundToSystemGesture)
			bound << QString::fromNSString(element.localizedName ?: @"?");
		// Not only the elements bound right now: the system can bind more later.
		element.preferredSystemGestureState = GCSystemGestureStateDisabled;
	}
	qCInfo(chiakiGui) << "Controller" << QString::fromNSString(controller.vendorName ?: @"?")
	                  << "system gestures disabled; were bound:" << bound;
	// macOS 27: the user decides whether the Home (PS) button follows the app's
	// preference. With the system default, macOS still opens the Game Overlay.
	const int in_app = controllerHomeButtonInAppAction();
	if (in_app == 0)
		qCWarning(chiakiGui) << "PS button: macOS keeps its own action in apps (Game Overlay); "
		                        "change it in System Settings > Game Controllers so the press only reaches the console";
	else if (in_app != -2)
		qCInfo(chiakiGui) << "PS button in-app setting" << in_app << "(1 = follows P5M, -1 = unreadable)";
}

int controllerHomeButtonInAppAction()
{
	if (@available(macOS 27.0, *)) {
		GCControllerHomeButtonSettingsManager *manager = [[GCControllerHomeButtonSettingsManager alloc] init];
		NSError *error = nil;
		return (int)[manager readControllerHomeButtonInAppActionWithError:&error];
	}
	return -2;
}

bool openControllerHomeButtonSettings()
{
	if (@available(macOS 27.0, *)) {
		GCControllerHomeButtonSettingsManager *manager = [[GCControllerHomeButtonSettingsManager alloc] init];
		NSError *error = nil;
		if ([manager openControllerHomeButtonSettingsForActivity:GCControllerHomeButtonSettingsCustomizeInAppActionActivity error:&error])
			return true;
		qCWarning(chiakiGui) << "Could not open the PS button settings:" << QString::fromNSString(error.localizedDescription ?: @"?");
	}
	return false;
}

void disableControllerSystemGestures()
{
	for (GCController *controller in GCController.controllers)
		disableGestures(controller);

	[NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidConnectNotification
	                                                object:nil
	                                                 queue:NSOperationQueue.mainQueue
	                                            usingBlock:^(NSNotification *note) {
		disableGestures((GCController *)note.object);
	}];
}

void hideCursorUntilMouseMoves()
{
	[NSCursor setHiddenUntilMouseMoves:YES];
}
