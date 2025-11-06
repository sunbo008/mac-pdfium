//
// Copyright 2024 The PDFium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//

#import <Cocoa/Cocoa.h>

// 自定义NSView子类,支持拖拽打开PDF文件
@interface DragDropView : NSView
@property(nonatomic, weak) id<NSApplicationDelegate> appDelegate;
@end
