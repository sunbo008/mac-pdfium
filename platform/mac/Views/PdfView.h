//
// Copyright 2024 The PDFium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//

#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "public/fpdf_doc.h"
#include "public/fpdfview.h"

// PdfView的委托协议
@protocol PdfViewDelegate <NSObject>
@optional
- (void)pdfViewDidChangePage:(id)sender;
- (void)pdfViewDidClickObject:(NSValue*)objectValue atIndex:(NSNumber*)index;
// 异步加载完成回调
- (void)pdfView:(id)sender
    didFinishLoadingDocument:(BOOL)success
                       error:(NSError*)error;
@end

@interface PdfView : NSView
@property(nonatomic, assign) id<PdfViewDelegate> delegate;
@property(nonatomic, readonly) NSString* currentPath;  // 当前打开的文件路径
- (BOOL)openPDFAtPath:(NSString*)path;
- (BOOL)openPDFAtPath:(NSString*)path
      showLoadingView:(BOOL)showLoading;  // 异步加载，可控制是否显示加载视图
- (void)cancelLoading;  // 取消当前加载操作
- (FPDF_DOCUMENT)document;
- (void)goToPage:(int)index;
- (int)currentPageIndex;          // 获取当前页索引（0开始）
- (NSSize)currentPageSizePt;      // 当前页 PDF 尺寸（pt）
- (void)updateViewSizeToFitPage;  // 根据页尺寸与缩放调整自身 frame
                                  // 大小（供滚动容器使用）
- (BOOL)findText:(NSString*)searchText
       fromIndex:(NSNumber*)startIndex;  // 文本查找功能
- (BOOL)exportCurrentPagePNG;            // 导出当前页为PNG
- (double)zoom;                          // 获取当前缩放比例
- (void)setZoom:(double)zoom;            // 设置缩放比例
@end
