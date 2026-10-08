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
