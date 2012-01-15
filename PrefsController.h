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
    NSButton *addOrDeleteBtn;
    
    BOOL newUser;
    BOOL didCancel;
}

@property (nonatomic) BOOL newUser;
@property (nonatomic) BOOL didCancel;
@property (nonatomic, retain) NSTextField *userText;

// IB Outlets/Actions
- (IBAction)cancelBtnClicked:(id)sender;
- (IBAction)addOrDeleteBtnClicked:(id)sender;
@property (assign) IBOutlet NSButton *addOrDeleteBtn;

@end
