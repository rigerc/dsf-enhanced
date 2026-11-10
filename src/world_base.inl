// [Debug] WorldBaseKey: a hotkey that leaves out parts of the city's global "base" LOD (GEGR, the
// region worldlod rebuilds), to see what the far map draws and which draws flicker. Off unless the
// key or WorldBaseMode is set. Findings: worldlod/research/world-lod.md, "Distant flicker while
// driving (2026-11-05)"; the base is drawn while driving too, not only in upper Shift.
//
// ShiftSector_EmitDrawMetadata (0x6BACB0, cdecl, 7 arguments) decides each placed model's draw, for
// the detailed regions and for the base alike; its two callers (0x6BB7DF, 0x6BB9DE) are pointed at
// ProxyEmitDrawMetadata, which skips the call when the mode says so. What it reads, as the function
// itself reads it (worldlod/research/world-lod.md, "How the engine switches base and detail"):
//  - sector +0x94 = descriptor; descriptor +0x10 != 0 for the base, +0x1C owner, +0x18 render state.
//  - instance i = first + index: GEBI record owner[+8][+4] + owner[+0x2C0C][i] * 0x14; its group is
//    (record +4 >> 20) & 0x19: 0 for building shells (technique chosen by cell residency), 1 for the
//    terrain parts (always the far technique). worldlod bakes its ground, trees and building detail
//    into those terrain parts, next to the stock sea and low trees.
//  - the instance's cell: render state +0x1E7B0 + i * 2, packed as (cell / 29, cell % 29); a
//    detailed cell is loaded when that pair is in the list at context[+0xD4] +0x347EC (end +0x347E8).
//  - a region model's cell: its GEBI header (owner +8) +0x08 u16 column, +0x0A u16 row, the same
//    pair (the world node's +0x0C); cell = row * 29 + column.
//
// Modes (the key steps through them; WorldBaseMode is the one the game starts in):
//  0 BASE ALL     everything drawn, as without this
//  1 BASE NONE    no base draws at all: is the base drawn while driving, and is it what flickers?
//  2 BASE SHELLS  the terrain parts left out (worldlod's bake, the stock sea and low trees)
//  3 BASE FAR     the terrain parts left out only where the cell is loaded and its own models were
//                 drawn in the last kWorldBaseDrawnMs ("loaded" alone empties Shift around the
//                 cursor: the cells stay loaded there while their detail isn't drawn)
// With the key set, every 2 s the log counts the calls by kind, loaded or not, and how many were skipped.

constexpr DWORD kEmitDrawMetadataRva = 0x002BACB0;
constexpr DWORD kEmitDrawMetadataCallRvas[] = {0x002BB7DF, 0x002BB9DE};
constexpr int kWorldBaseModes = 4;
const char* const kWorldBaseModeNames[kWorldBaseModes] = {"BASE ALL", "BASE NONE", "BASE SHELLS", "BASE FAR"};

using EmitDrawMetadataFn = void (__cdecl*)(int, int, int*, int*, std::uint8_t*, std::uint8_t*, std::uint32_t);
EmitDrawMetadataFn g_emit_draw_metadata = nullptr;

volatile LONG g_world_base_mode = 0;
int g_world_base_vk = 0;
char g_world_base_key_name[16] = {};
DWORD g_world_base_shown_at = 0;
volatile bool g_world_base_showing = false;

// Calls per kind since the last log line: WorldBaseClassify's result (kind | 4 when loaded, | 16
// when the cell's detail was drawn lately, | 8 on a fault), and the calls skipped.
volatile LONG g_world_base_counts[32] = {};

// GetTickCount of the last region model drawn in each cell (row * 29 + column).
constexpr int kWorldBaseCells = 29 * 64;
constexpr DWORD kWorldBaseDrawnMs = 150;
volatile DWORD g_cell_detail_drawn_at[kWorldBaseCells] = {};
volatile LONG g_world_base_skipped = 0;
DWORD g_world_base_logged_at = 0;

enum WorldBaseKind
{
    kWorldBaseRegion = 0,   // a detailed region's model
    kWorldBaseShell = 1,    // base, group 0: the building shells
    kWorldBaseTerrain = 2,  // base, group 1: the terrain parts (worldlod's bake is in these)
    kWorldBaseOther = 3,    // base, another group
    kWorldBaseLoaded = 4,
    kWorldBaseFault = 8,
    kWorldBaseDrawn = 16,
};

template <typename T>
T WorldBaseRead(const std::uint8_t* address)
{
    T value;
    std::memcpy(&value, address, sizeof(value));
    return value;
}

// The reads stay in a call of their own: clang-cl (with /EHsc) catches a fault in a called
// function but drops the handler for a read in the __try's own function.
__declspec(noinline) int WorldBaseClassifyUnguarded(int first, int index, const std::uint8_t* sector,
    const std::uint8_t* context)
{
    const auto* descriptor = WorldBaseRead<const std::uint8_t*>(sector + 0x94);
    const auto* owner = WorldBaseRead<const std::uint8_t*>(descriptor + 0x1C);
    if (descriptor[0x10] == 0) {
        const auto* gebi = WorldBaseRead<const std::uint8_t*>(owner + 8);
        const auto column = WorldBaseRead<std::uint16_t>(gebi + 0x08);
        const auto row = WorldBaseRead<std::uint16_t>(gebi + 0x0A);
        if (column < 29 && row * 29 + column < kWorldBaseCells) {
            g_cell_detail_drawn_at[row * 29 + column] = GetTickCount();
        }
        return kWorldBaseRegion;
    }
    const auto* state = WorldBaseRead<const std::uint8_t*>(descriptor + 0x18);
    const int i = first + index;
    const auto record_index = WorldBaseRead<std::uint16_t>(WorldBaseRead<const std::uint8_t*>(owner + 0x2C0C) + i * 2);
    const auto* records = WorldBaseRead<const std::uint8_t*>(WorldBaseRead<const std::uint8_t*>(owner + 8) + 4);
    const std::uint32_t group = (WorldBaseRead<std::uint32_t>(records + record_index * 0x14 + 4) >> 20) & 0x19;
    const int kind = group == 0 ? kWorldBaseShell : group == 1 ? kWorldBaseTerrain : kWorldBaseOther;

    const auto cell = WorldBaseRead<std::uint16_t>(state + 0x1E7B0 + i * 2);
    const int drawn = cell < kWorldBaseCells && GetTickCount() - g_cell_detail_drawn_at[cell] < kWorldBaseDrawnMs
        ? kWorldBaseDrawn : 0;
    const std::uint32_t key = (static_cast<std::uint32_t>(cell / 29) << 16) | (cell % 29);
    const auto* world = WorldBaseRead<const std::uint8_t*>(context + 0xD4);
    const std::uint8_t* end = world + 0x347E8;
    const auto* node = WorldBaseRead<const std::uint8_t*>(world + 0x347EC);
    for (int guard = 0; node != end && node != nullptr && guard < 4096; ++guard) {
        if (WorldBaseRead<std::uint32_t>(node + 0x0C) == key) {
            return kind | kWorldBaseLoaded | drawn;
        }
        node = WorldBaseRead<const std::uint8_t*>(node + 4);
    }
    return kind | drawn;
}

int WorldBaseClassify(int first, int index, const std::uint8_t* sector, const std::uint8_t* context)
{
    __try {
        return WorldBaseClassifyUnguarded(first, index, sector, context);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return kWorldBaseOther | kWorldBaseFault;
    }
}

int WorldBaseMode()
{
    return g_world_base_mode;
}

void __cdecl ProxyEmitDrawMetadata(int first, int index, int* list, int* technique, std::uint8_t* sector,
    std::uint8_t* context, std::uint32_t flag)
{
    const int mode = WorldBaseMode();
    if (mode == 0 && g_world_base_vk == 0) {
        g_emit_draw_metadata(first, index, list, technique, sector, context, flag);
        return;
    }
    const int kind = WorldBaseClassify(first, index, sector, context);
    InterlockedIncrement(&g_world_base_counts[kind & 31]);
    const int base_kind = kind & 3;
    bool skip = false;
    switch (mode) {
    case 1:
        skip = base_kind != kWorldBaseRegion;
        break;
    case 2:
        skip = base_kind == kWorldBaseTerrain;
        break;
    case 3:
        skip = base_kind == kWorldBaseTerrain && (kind & (kWorldBaseLoaded | kWorldBaseDrawn)) == (kWorldBaseLoaded | kWorldBaseDrawn);
        break;
    default:
        break;
    }
    if (skip) {
        InterlockedIncrement(&g_world_base_skipped);
        return;
    }
    g_emit_draw_metadata(first, index, list, technique, sector, context, flag);
}

void LoadWorldBaseConfig(const char* ini_path)
{
    GetPrivateProfileStringA("Debug", "WorldBaseKey", "", g_world_base_key_name, sizeof(g_world_base_key_name), ini_path);
    const int vk = ToggleParseKey(g_world_base_key_name);
    if (vk < 0) {
        Log("WorldBase: [Debug] WorldBaseKey=%s is not a key name or code; off", g_world_base_key_name);
    }
    g_world_base_vk = std::max(vk, 0);
    g_world_base_mode = ClampInt(GetPrivateProfileIntA("Debug", "WorldBaseMode", 0, ini_path), 0, kWorldBaseModes - 1);
}

DWORD WINAPI WorldBaseKeyThread(LPVOID)
{
    bool was_down = false;
    for (;;) {
        const bool down = (GetAsyncKeyState(g_world_base_vk) & 0x8000) != 0;
        if (down && !was_down && ToggleGameInFront()) {
            const LONG mode = (WorldBaseMode() + 1) % kWorldBaseModes;
            InterlockedExchange(&g_world_base_mode, mode);
            g_world_base_shown_at = GetTickCount();
            g_world_base_showing = true;
            Log("WorldBase: mode %ld, %s (%s)", static_cast<long>(mode), kWorldBaseModeNames[mode], g_world_base_key_name);
        }
        was_down = down;
        Sleep(20);
    }
}

void ApplyWorldBasePatch(const ModuleRange& range)
{
    if (g_world_base_vk == 0 && g_world_base_mode == 0) {
        return;
    }
    if (!IsRvaInRange(range, kEmitDrawMetadataRva, 16)) {
        Log("WorldBase: Driver.exe is not the expected build; off");
        return;
    }
    std::uint8_t* const target = range.base + kEmitDrawMetadataRva;
    CodePatch patches[2];
    for (int i = 0; i < 2; ++i) {
        std::uint8_t* const site = range.base + kEmitDrawMetadataCallRvas[i];
        if (!IsRvaInRange(range, kEmitDrawMetadataCallRvas[i], 5) || !CallsTarget(site, target)) {
            Log("WorldBase: call site RVA 0x%08lX does not call ShiftSector_EmitDrawMetadata; off",
                static_cast<unsigned long>(kEmitDrawMetadataCallRvas[i]));
            return;
        }
        patches[i] = MakeCodePatch(site, 5);
        SetRel32(patches[i], 0xE8, reinterpret_cast<const void*>(&ProxyEmitDrawMetadata));
    }
    g_emit_draw_metadata = reinterpret_cast<EmitDrawMetadataFn>(target);
    if (!WriteCodePatches(patches, 2, "WorldBase")) {
        return;
    }
    g_world_base_logged_at = GetTickCount();
    if (g_world_base_vk != 0) {
        const HANDLE thread = CreateThread(nullptr, 0, WorldBaseKeyThread, nullptr, 0, nullptr);
        if (thread != nullptr) {
            CloseHandle(thread);
        }
    }
    Log("WorldBase: debug hook in, mode %ld (%s), key %s", static_cast<long>(g_world_base_mode),
        kWorldBaseModeNames[g_world_base_mode], g_world_base_vk != 0 ? g_world_base_key_name : "none");
}

// InitThread, every 250 ms: one line every 2 s while the hook is in and the game draws.
void LogWorldBaseStats()
{
    if (g_emit_draw_metadata == nullptr || g_world_base_vk == 0) {
        return;
    }
    const DWORD now = GetTickCount();
    if (now - g_world_base_logged_at < 2000) {
        return;
    }
    const DWORD seconds_x10 = std::max<DWORD>(1, (now - g_world_base_logged_at) / 100);
    g_world_base_logged_at = now;
    LONG all[4] = {}, loaded[4] = {}, drawn[4] = {};
    LONG faults = 0;
    LONG total = InterlockedExchange(&g_world_base_skipped, 0);
    const LONG skipped = total;
    for (int i = 0; i < 32; ++i) {
        const LONG n = InterlockedExchange(&g_world_base_counts[i], 0);
        total += n;
        if ((i & kWorldBaseFault) != 0) {
            faults += n;
            continue;
        }
        all[i & 3] += n;
        loaded[i & 3] += (i & kWorldBaseLoaded) != 0 ? n : 0;
        drawn[i & 3] += (i & kWorldBaseDrawn) != 0 ? n : 0;
    }
    if (total == 0) {
        return;
    }
    auto per_s = [seconds_x10](LONG n) { return static_cast<long>(n * 10 / static_cast<LONG>(seconds_x10)); };
    Log("WorldBase: mode %ld; calls/s: region %ld, base shells %ld (cell loaded %ld, detail drawn %ld), base terrain "
        "parts %ld (loaded %ld, drawn %ld), base other %ld (loaded %ld, drawn %ld), faults %ld; skipped %ld",
        static_cast<long>(WorldBaseMode()), per_s(all[0]), per_s(all[1]), per_s(loaded[1]), per_s(drawn[1]),
        per_s(all[2]), per_s(loaded[2]), per_s(drawn[2]), per_s(all[3]), per_s(loaded[3]), per_s(drawn[3]),
        per_s(faults), per_s(skipped));
}

// TogglesFrameEnd (with DLSS 5 or DLAA on, whose Present hook it runs from): the mode for 2 s
// after a press, under the DLSS 5 and DLAA lines.
void WorldBaseFrameEnd(IDirect3DDevice9* device)
{
    if (!g_world_base_showing) {
        return;
    }
    if (GetTickCount() - g_world_base_shown_at >= kToggleIndicatorMs) {
        g_world_base_showing = false;
        return;
    }
    IDirect3DSurface9* back = nullptr;
    D3DSURFACE_DESC desc = {};
    if (FAILED(device->GetBackBuffer(0, 0, D3DBACKBUFFER_TYPE_MONO, &back)) || back == nullptr || FAILED(back->GetDesc(&desc))) {
        D5SafeRelease(back);
        return;
    }
    g_d5_internal = true;
    D5SavedTargets saved;
    D5SaveTargets(device, &saved);
    D3DVIEWPORT9 viewport = {};
    device->GetViewport(&viewport);
    DWORD scissor = FALSE;
    DWORD write_mask = 0xF;
    device->GetRenderState(D3DRS_SCISSORTESTENABLE, &scissor);
    device->GetRenderState(D3DRS_COLORWRITEENABLE, &write_mask);
    device->SetRenderTarget(0, back);
    for (DWORD i = 1; i < 4; ++i) {
        device->SetRenderTarget(i, nullptr);
    }
    device->SetDepthStencilSurface(nullptr);
    device->SetRenderState(D3DRS_SCISSORTESTENABLE, FALSE);
    device->SetRenderState(D3DRS_COLORWRITEENABLE, 0xF);

    const LONG scale = std::max<LONG>(2, static_cast<LONG>(desc.Height) / 240);
    const char* text = kWorldBaseModeNames[WorldBaseMode()];
    const LONG x = 8 * scale;
    const LONG y = 8 * scale + 2 * 13 * scale;   // below the DLSS 5 and DLAA lines
    const LONG width = static_cast<LONG>(std::strlen(text)) * 6 * scale - scale;
    const D3DRECT box = {x - 2 * scale, y - 2 * scale, x + width + 2 * scale, y + 9 * scale};
    g_d5_clear(device, 1, &box, D3DCLEAR_TARGET, D3DCOLOR_XRGB(0, 0, 0), 1.0f, 0);
    D3DRECT rects[256];
    const int count = ToggleTextRects(text, x, y, scale, rects, 0, 256);
    g_d5_clear(device, static_cast<DWORD>(count), rects, D3DCLEAR_TARGET, D3DCOLOR_XRGB(255, 220, 0), 1.0f, 0);

    D5RestoreTargets(device, &saved);
    device->SetViewport(&viewport);
    device->SetRenderState(D3DRS_SCISSORTESTENABLE, scissor);
    device->SetRenderState(D3DRS_COLORWRITEENABLE, write_mask);
    g_d5_internal = false;
    back->Release();
}
