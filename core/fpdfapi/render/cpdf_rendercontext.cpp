// Copyright 2016 The PDFium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Original code copyright 2014 Foxit Software Inc. http://www.foxitsoftware.com

#include "core/fpdfapi/render/cpdf_rendercontext.h"

#include <utility>

#include "build/build_config.h"
#include "core/fpdfapi/page/cpdf_form.h"
#include "core/fpdfapi/page/cpdf_pageimagecache.h"
#include "core/fpdfapi/page/cpdf_pageobject.h"
#include "core/fpdfapi/page/cpdf_pageobjectholder.h"
#include "core/fpdfapi/parser/cpdf_dictionary.h"
#include "core/fpdfapi/parser/cpdf_document.h"
#include "core/fpdfapi/render/cpdf_progressiverenderer.h"
#include "core/fpdfapi/render/cpdf_renderoptions.h"
#include "core/fpdfapi/render/cpdf_renderstatus.h"
#include "core/fpdfapi/render/cpdf_textrenderer.h"
#include "platform/shared/logger.h"  // [AP-FORM-IMAGE-WATERMARK]
#include "core/fxcrt/check.h"
#include "core/fxge/cfx_defaultrenderdevice.h"
#include "core/fxge/cfx_renderdevice.h"
#include "core/fxge/dib/cfx_dibitmap.h"
#include "core/fxge/dib/fx_dib.h"

CPDF_RenderContext::CPDF_RenderContext(
    CPDF_Document* doc,
    RetainPtr<CPDF_Dictionary> pPageResources,
    CPDF_PageImageCache* pPageCache)
    : document_(doc),
      page_resources_(std::move(pPageResources)),
      page_cache_(pPageCache) {}

CPDF_RenderContext::~CPDF_RenderContext() = default;

void CPDF_RenderContext::GetBackgroundToDevice(
    CFX_RenderDevice* device,
    const CPDF_PageObject* object,
    const CPDF_RenderOptions* options,
    const CFX_Matrix& matrix) {
  device->FillRect(FX_RECT(0, 0, device->GetWidth(), device->GetHeight()),
                   0xffffffff);
  Render(device, object, options, &matrix);
}

#if BUILDFLAG(IS_WIN)
void CPDF_RenderContext::GetBackgroundToBitmap(RetainPtr<CFX_DIBitmap> bitmap,
                                               const CPDF_PageObject* object,
                                               const CFX_Matrix& matrix) {
  CFX_DefaultRenderDevice device;
  device.Attach(std::move(bitmap));
  GetBackgroundToDevice(&device, object, /*options=*/nullptr, matrix);
}
#endif

void CPDF_RenderContext::AppendLayer(CPDF_PageObjectHolder* pObjectHolder,
                                     const CFX_Matrix& mtObject2Device) {
  layers_.emplace_back(pObjectHolder, mtObject2Device);
}

void CPDF_RenderContext::Render(CFX_RenderDevice* pDevice,
                                const CPDF_PageObject* pStopObj,
                                const CPDF_RenderOptions* pOptions,
                                const CFX_Matrix* pLastMatrix) {
  // [AP-FORM-IMAGE-WATERMARK] 调试：检查 Render 入口的回调状态
  LOG_DEBUG_F("[AP-FORM-IMAGE-WATERMARK] RenderContext::Render: image_callback_=%s",
              (image_callback_ ? "valid" : "null"));
  
  for (auto& layer : layers_) {
    CFX_RenderDevice::StateRestorer restorer(pDevice);
    CPDF_RenderStatus status(this, pDevice);
    if (pOptions) {
      status.SetOptions(*pOptions);
    }
    status.SetStopObject(pStopObj);
    status.SetTransparency(layer.GetObjectHolder()->GetTransparency());
    
    // [AP-FORM-IMAGE-WATERMARK] 检查 layer 是否是 AP-Form
    // 只有两种派生：CPDF_Page 和 CPDF_Form。非 Page 即 Form。
    bool is_page = layer.GetObjectHolder()->IsPage();
    LOG_DEBUG_F("[AP-FORM-IMAGE-WATERMARK] Layer IsPage=%s", (is_page ? "true" : "false"));
    
    if (!is_page) {
      CPDF_Form* pForm = static_cast<CPDF_Form*>(layer.GetObjectHolder());
      bool is_ap_form = pForm ? pForm->IsAPForm() : false;
      LOG_DEBUG_F("[AP-FORM-IMAGE-WATERMARK] pForm=%p, IsAPForm=%s", 
                  pForm, (is_ap_form ? "true" : "false"));
      
      if (pForm && is_ap_form) {
        status.SetInAppearanceForm(true);
        LOG_INFO_F("[AP-FORM-IMAGE-WATERMARK] Set status.SetInAppearanceForm(true) for AP-Form layer");
      }
    }
    
    // [AP-FORM-IMAGE-WATERMARK] 传播回调
    if (image_callback_) {
      status.SetImageCallback(
          static_cast<CPDF_RenderStatus::ImageCallbackIface*>(image_callback_));
      LOG_DEBUG_F("[AP-FORM-IMAGE-WATERMARK] Set callback to status in Render()");
    } else {
      LOG_DEBUG_F("[AP-FORM-IMAGE-WATERMARK] No callback to set in Render()");
    }
    
    CFX_Matrix final_matrix = layer.GetMatrix();
    if (pLastMatrix) {
      final_matrix *= *pLastMatrix;
      status.SetDeviceMatrix(*pLastMatrix);
    }
    status.Initialize(nullptr, nullptr);
    status.RenderObjectList(layer.GetObjectHolder(), final_matrix);
    if (status.GetRenderOptions().GetOptions().bLimitedImageCache) {
      page_cache_->CacheOptimization(
          status.GetRenderOptions().GetCacheSizeLimit());
    }
    if (status.IsStopped()) {
      break;
    }
  }
}

CPDF_RenderContext::Layer::Layer(CPDF_PageObjectHolder* pHolder,
                                 const CFX_Matrix& matrix)
    : object_holder_(pHolder), matrix_(matrix) {}

CPDF_RenderContext::Layer::Layer(const Layer& that) = default;

CPDF_RenderContext::Layer::~Layer() = default;
