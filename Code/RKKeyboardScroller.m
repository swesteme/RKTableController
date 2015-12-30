//
//  RKKeyboardScroller.m
//  RestKit
//
//  Created by Blake Watters on 7/5/12.
//  Copyright (c) 2012 RestKit, Inc. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#import "RKKeyboardScroller.h"
#import <RestKit/RestKit.h>
#import "UIView+FindFirstResponder.h"

// Define logging component
#undef RKLogComponent
#define RKLogComponent RKlcl_cRestKitUI

@interface RKKeyboardScroller ()

@property (nonatomic, weak, readwrite) UIViewController *viewController;
@property (nonatomic, weak, readwrite) UIScrollView *scrollView;
@end

@implementation RKKeyboardScroller

- (id)init
{
    RKLogError(@"Failed to call designated initialized initWithViewController:");
    [self doesNotRecognizeSelector:_cmd];
    return nil;
}

- (id)initWithViewController:(UIViewController *)viewController scrollView:(UIScrollView *)scrollView
{
    NSAssert(viewController, @"%@ must be instantiated with a viewController.", [self class]);
    NSAssert(scrollView, @"%@ must be instantiated with a scrollView.", [self class]);

    self = [super init];
    if (self) {
        self.viewController = viewController;
        self.scrollView = scrollView;

        // Register for Keyboard notifications
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleKeyboardNotification:)
                                                     name:UIKeyboardWillShowNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleKeyboardNotification:)
                                                     name:UIKeyboardWillHideNotification
                                                   object:nil];
    }

    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)handleKeyboardNotification:(NSNotification *)notification
{
    if (!self.viewController.isViewLoaded || self.viewController.view.window == nil) return;

    NSDictionary *userInfo = [notification userInfo];

    CGRect keyboardEndFrame = [[userInfo objectForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue];
    RKLogTrace(@"keyboardEndFrame=%@", NSStringFromCGRect(keyboardEndFrame));

    CGRect scrollViewFrame = self.scrollView.frame;
    RKLogTrace(@"scrollViewFrame=%@", NSStringFromCGRect(scrollViewFrame));

    CGRect convertedScrollViewFrame = [self.scrollView.superview convertRect:scrollViewFrame toView:nil];
    RKLogTrace(@"convertedScrollViewFrame=%@", NSStringFromCGRect(convertedScrollViewFrame));

    CGRect keyboardOverlap = CGRectIntersection(convertedScrollViewFrame, keyboardEndFrame);
    RKLogTrace(@"keyboardOverlap=%@", NSStringFromCGRect(keyboardOverlap));

    if ([[notification name] isEqualToString:UIKeyboardWillShowNotification]) {
        [UIView beginAnimations:nil context:nil];
        [UIView setAnimationDuration:0.2];

        if (! CGRectEqualToRect(keyboardOverlap, CGRectNull)) {
            UIEdgeInsets contentInsets = UIEdgeInsetsMake(0, 0, keyboardOverlap.size.height, 0);
            self.scrollView.contentInset = contentInsets;
            self.scrollView.scrollIndicatorInsets = contentInsets;
        }

        UIView *firstResponder = [self.scrollView findFirstResponder];
        if (firstResponder) {
            CGRect firstResponderFrame = firstResponder.frame;
            RKLogTrace(@"Found firstResponder=%@ at %@", firstResponder, NSStringFromCGRect(firstResponderFrame));

            if (![firstResponder.superview isEqual:self.scrollView]) {
                firstResponderFrame = [firstResponder.superview convertRect:firstResponderFrame toView:self.scrollView];
                RKLogTrace(@"firstResponder (%@) frame is not in self.scrollView's coordinate system. Coverted to %@",
                           firstResponder, NSStringFromCGRect(firstResponderFrame));
            }

            RKLogTrace(@"firstResponder (%@) is underneath keyboard. Scrolling scroll view to show", firstResponder);
            if ([self.scrollView isKindOfClass:[UITableView class]]) {
                // Scroll to the row containing the point if this is a table view
                NSIndexPath *indexPath = [(UITableView *)self.scrollView indexPathForRowAtPoint:firstResponderFrame.origin];
                if (indexPath) {
                    [(UITableView *)self.scrollView scrollToRowAtIndexPath:indexPath atScrollPosition:UITableViewScrollPositionMiddle animated:YES];
                } else {
                    // Fall back plan
                    [self.scrollView scrollRectToVisible:firstResponderFrame animated:YES];
                }
            } else {
                // Otherwise fall back to the vanilla scroll view flavor
                [self.scrollView scrollRectToVisible:firstResponderFrame animated:YES];
            }
        }
        [UIView commitAnimations];

    } else if ([[notification name] isEqualToString:UIKeyboardWillHideNotification]) {
        [UIView beginAnimations:nil context:nil];
        [UIView setAnimationDuration:0.2];
        UIEdgeInsets contentInsets = UIEdgeInsetsZero;
        self.scrollView.contentInset = contentInsets;
        self.scrollView.scrollIndicatorInsets = contentInsets;
        [UIView commitAnimations];
    }
}

@end
