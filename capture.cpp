#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <wincodec.h>
#include <wrl/client.h>
#include <cstdio>
#include <vector>

using Microsoft::WRL::ComPtr;

#define CHECK(expression) do { const HRESULT result = (expression); if (FAILED(result)) return result; } while (false)

HRESULT WritePng(ID3D11Texture2D* texture, ID3D11DeviceContext* context,
                 const D3D11_TEXTURE2D_DESC& desc, const wchar_t* path)
{
    ComPtr<IWICImagingFactory> factory;
    CHECK(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                           IID_PPV_ARGS(factory.GetAddressOf())));
    ComPtr<IWICStream> stream;
    CHECK(factory->CreateStream(stream.GetAddressOf()));
    CHECK(stream->InitializeFromFilename(path, GENERIC_WRITE));
    ComPtr<IWICBitmapEncoder> encoder;
    CHECK(factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, encoder.GetAddressOf()));
    CHECK(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache));
    ComPtr<IWICBitmapFrameEncode> frame;
    CHECK(encoder->CreateNewFrame(frame.GetAddressOf(), nullptr));
    CHECK(frame->Initialize(nullptr));
    CHECK(frame->SetSize(desc.Width, desc.Height));
    WICPixelFormatGUID format = GUID_WICPixelFormat24bppBGR;
    CHECK(frame->SetPixelFormat(&format));
    if (!IsEqualGUID(format, GUID_WICPixelFormat24bppBGR)) return E_UNEXPECTED;

    const UINT stride = desc.Width * 3;
    std::vector<BYTE> bgr(stride * desc.Height);
    D3D11_MAPPED_SUBRESOURCE pixels{};
    CHECK(context->Map(texture, 0, D3D11_MAP_READ, 0, &pixels));
    const auto* bytes = static_cast<const BYTE*>(pixels.pData);
    for (UINT y = 0; y < desc.Height; ++y) {
        const BYTE* source = bytes + y * pixels.RowPitch;
        BYTE* target = bgr.data() + y * stride;
        for (UINT x = 0; x < desc.Width; ++x) {
            target[0] = source[0];
            target[1] = source[1];
            target[2] = source[2];
            source += 4;
            target += 3;
        }
    }
    context->Unmap(texture, 0);
    CHECK(frame->WritePixels(desc.Height, stride, static_cast<UINT>(bgr.size()), bgr.data()));
    CHECK(frame->Commit());
    return encoder->Commit();
}

HRESULT CaptureOutput(IDXGIAdapter1* adapter, IDXGIOutput* output, const wchar_t* path)
{
    ComPtr<IDXGIOutput1> captureOutput;
    CHECK(output->QueryInterface(IID_PPV_ARGS(captureOutput.GetAddressOf())));
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    CHECK(D3D11CreateDevice(adapter, D3D_DRIVER_TYPE_UNKNOWN, nullptr, 0, nullptr, 0,
                            D3D11_SDK_VERSION, device.GetAddressOf(), nullptr,
                            context.GetAddressOf()));
    ComPtr<IDXGIOutputDuplication> duplication;
    CHECK(captureOutput->DuplicateOutput(device.Get(), duplication.GetAddressOf()));
    DXGI_OUTDUPL_DESC outputDesc{};
    duplication->GetDesc(&outputDesc);
    if (outputDesc.Rotation != DXGI_MODE_ROTATION_IDENTITY) return E_NOTIMPL;

    DXGI_OUTDUPL_FRAME_INFO info{};
    ComPtr<IDXGIResource> resource;
    // The first frame can contain only a pointer update.
    for (int attempt = 0; attempt < 4; ++attempt) {
        CHECK(duplication->AcquireNextFrame(150, &info, resource.GetAddressOf()));
        if (info.LastPresentTime.QuadPart != 0) break;
        resource.Reset();
        CHECK(duplication->ReleaseFrame());
    }
    if (!resource) return DXGI_ERROR_WAIT_TIMEOUT;

    ComPtr<ID3D11Texture2D> source;
    CHECK(resource.As(&source));
    D3D11_TEXTURE2D_DESC desc{};
    source->GetDesc(&desc);
    if (desc.Format != DXGI_FORMAT_B8G8R8A8_UNORM) return E_NOTIMPL;
    desc.Usage = D3D11_USAGE_STAGING;
    desc.BindFlags = 0;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    desc.MiscFlags = 0;
    ComPtr<ID3D11Texture2D> staging;
    CHECK(device->CreateTexture2D(&desc, nullptr, staging.GetAddressOf()));
    context->CopyResource(staging.Get(), source.Get());
    CHECK(duplication->ReleaseFrame());
    return WritePng(staging.Get(), context.Get(), desc, path);
}

HRESULT Capture(const wchar_t* deviceName, const wchar_t* path)
{
    ComPtr<IDXGIFactory1> factory;
    CHECK(CreateDXGIFactory1(IID_PPV_ARGS(factory.GetAddressOf())));
    for (UINT index = 0; ; ++index) {
        ComPtr<IDXGIAdapter1> adapter;
        const HRESULT nextAdapter = factory->EnumAdapters1(index, adapter.GetAddressOf());
        if (nextAdapter == DXGI_ERROR_NOT_FOUND) return nextAdapter;
        CHECK(nextAdapter);
        for (UINT indexOutput = 0; ; ++indexOutput) {
            ComPtr<IDXGIOutput> output;
            const HRESULT nextOutput = adapter->EnumOutputs(indexOutput, output.GetAddressOf());
            if (nextOutput == DXGI_ERROR_NOT_FOUND) break;
            CHECK(nextOutput);
            DXGI_OUTPUT_DESC desc{};
            CHECK(output->GetDesc(&desc));
            if (desc.AttachedToDesktop && lstrcmpiW(deviceName, desc.DeviceName) == 0)
                return CaptureOutput(adapter.Get(), output.Get(), path);
        }
    }
}

int wmain(int argc, wchar_t** argv)
{
    if (argc != 3) return 2;
    HRESULT result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (SUCCEEDED(result)) {
        result = Capture(argv[1], argv[2]);
        CoUninitialize();
    }
    if (FAILED(result)) {
        std::printf("DXGI capture failed (0x%08lX).\n", static_cast<unsigned long>(result));
        return 1;
    }
    return 0;
}
