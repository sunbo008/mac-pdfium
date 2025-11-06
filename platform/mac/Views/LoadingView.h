//
// Copyright 2024 The PDFium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//

#import <Cocoa/Cocoa.h>

// LoadingView - 显示加载进度的半透明覆盖层
// 包含旋转的spinner、带省略号动画的文字和取消按钮
@interface LoadingView : NSView

// 取消按钮点击回调
@property(nonatomic, copy) void (^onCancel)(void);

// 显示加载视图（开始动画）
- (void)show;

// 隐藏加载视图（停止动画）
- (void)hide;

@end

