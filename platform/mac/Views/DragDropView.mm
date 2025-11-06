//
// Copyright 2024 The PDFium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//

#import "DragDropView.h"

@implementation DragDropView

- (instancetype)initWithFrame:(NSRect)frameRect {
  self = [super initWithFrame:frameRect];
  if (self) {
    // 注册接受的拖拽类型
    [self registerForDraggedTypes:@[ NSPasteboardTypeFileURL ]];
  }
  return self;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
  NSPasteboard* pboard = [sender draggingPasteboard];

  if ([[pboard types] containsObject:NSPasteboardTypeFileURL]) {
    // 获取文件URL
    NSURL* fileURL = [NSURL URLFromPasteboard:pboard];
    if (fileURL &&
        [fileURL.pathExtension.lowercaseString isEqualToString:@"pdf"]) {
      return NSDragOperationCopy;
    }
  }

  return NSDragOperationNone;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
  NSPasteboard* pboard = [sender draggingPasteboard];

  if ([[pboard types] containsObject:NSPasteboardTypeFileURL]) {
    NSURL* fileURL = [NSURL URLFromPasteboard:pboard];
    if (fileURL &&
        [fileURL.pathExtension.lowercaseString isEqualToString:@"pdf"]) {
      // 获取文件路径
      NSString* filePath = fileURL.path;

      // 调用 AppDelegate 的打开文件方法
      if (self.appDelegate &&
          [self.appDelegate respondsToSelector:@selector(openPathAndAdjust:)]) {
        [(id)self.appDelegate performSelector:@selector(openPathAndAdjust:)
                                   withObject:filePath];
        return YES;
      }
    }
  }

  return NO;
}

@end
