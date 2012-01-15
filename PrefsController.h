//
//  PrefsController.h
//  GoogleHealthWeight
//
//  Created by Ford Parsons on 10/10/10.
//  Copyright 2010 Ford Parsons. All rights reserved.
//

#import <Foundation/Foundation.h>


@interface PrefsController : NSWindowController {
	IBOutlet NSWindow* configureSheet;
    IBOutlet NSWindow* mainWindow;

	IBOutlet NSTextField* userText;
	IBOutlet NSSecureTextField* passText;
}
- (IBAction)closePrefs:(id)sender;
- (IBAction)saveAndClosePrefs:(id)sender;

@end
