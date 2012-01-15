//
//  FPLevelIndicator.m
//  GoogleHealthWeight
//
//  Created by Ford Parsons on 11/23/10.
//  Copyright 2010 Ford Parsons. All rights reserved.
//

#import "FPLevelIndicator.h"

@implementation FPLevelIndicator

@synthesize lowCriticalValue, lowWarningValue, highWarningValue, highCriticalValue;

- (id)initWithFrame:(NSRect)frameRect
{
	if(self = [super initWithFrame:frameRect])
	{
		[self.cell setLevelIndicatorStyle:NSContinuousCapacityLevelIndicatorStyle];
	}
	return self;
}

- (void)setDoubleValue:(double)aDouble
{	
	[super setDoubleValue:aDouble];
	
	if(aDouble < lowCriticalValue || aDouble > highCriticalValue) {
		[self setWarningValue:aDouble - 2];
		[self setCriticalValue:aDouble - 1];
	} else if(aDouble < lowWarningValue || aDouble > highWarningValue) {
		[self setWarningValue:aDouble - 1];
		[self setCriticalValue:aDouble + 1];
	} else {
		[self setWarningValue:aDouble + 1];
		[self setCriticalValue:aDouble + 2];
	}
}

@end
