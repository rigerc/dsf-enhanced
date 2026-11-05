#pragma once

// [Ultrawide] FOVScaling: the instructions in Driver.exe 1.04 that turn a camera FOV from degrees
// into radians (issue #32). The game has one degrees-to-radians constant, 0.017453 at
// 0x00DD9A80 (RVA 0x009D9A80), and 45 instructions read it. Earlier builds widened the FOV by
// writing the scaled value over that constant, which also scaled every other reader, so every
// cockpit needle (0x008A2610: sweep x 0x00DD9A80 x input) turned 1.34x too far at 21:9. Now the
// constant keeps its value and only the reads below, whose result becomes a camera's FOV, are
// pointed at a float of the plugin's own.
//
// How the sites were found: every copy of the address 0x00DD9A80 in the image is an instruction
// operand in .text (no data pointer holds it). The camera's FOV is the float at camera +0x1E0
// (the Lua getter "fov", 0x006113E0, reads it through 0x005AB5C0; 0x005AB600 sets it). Each read
// below ends in that field: stored there, passed to 0x005AB600, or added to it.
// No Windows dependency; tests/fov_sites_test.cpp checks the table, and with a Driver.exe path
// it also checks the table against the game's bytes.

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace fovsites {

constexpr std::uint32_t kImageBase = 0x00400000;   // Driver.exe has no relocations
constexpr std::uint32_t kDegreesToRadiansRva = 0x009D9A80;
constexpr std::uint32_t kDegreesToRadiansBits = 0x3C8EFA35;   // 0.017453293

struct Site
{
    std::uint32_t rva;
    std::uint8_t size;      // instruction length; the address is its last 4 bytes
    std::uint8_t opcode[4]; // the bytes before the address
    const char* reader;     // for the log and the test
};

// The reads whose result becomes a camera FOV. Each instruction keeps its opcode; only its
// address operand changes.
constexpr Site kFovSites[] = {
    // FUN_005AF940: FOV between camera params +0x3140 and +0x3144 (degrees when above 3); both
    // callers (0x5B086D, 0x5B2A47) store the result at camera +0x1E0.
    {0x001AF95B, 8, {0xF3, 0x0F, 0x10, 0x0D}, "camera FOV blend (0x5AF940)"},
    // FUN_005B4AF0: camera +0x1E0 = param +0x34EC, plain and with the 0.4 pull-in.
    {0x001B4F10, 8, {0xF3, 0x0F, 0x59, 0x05}, "camera FOV (0x5B4AF0)"},
    {0x001B4F78, 8, {0xF3, 0x0F, 0x59, 0x05}, "camera FOV pull-in (0x5B4AF0)"},
    // FUN_005B5630: camera +0x1E0 = param +0x34EC.
    {0x001B5787, 8, {0xF3, 0x0F, 0x59, 0x05}, "camera FOV (0x5B5630)"},
    // FUN_005B6420: 0x5AB600 (set FOV) with param +0x3394.
    {0x001B65F2, 8, {0xF3, 0x0F, 0x59, 0x05}, "camera FOV set (0x5B6420)"},
    // FUN_005B77E0 and FUN_005B8350: camera +0x1E0 = blend of params +0x3340 and +0x34E0 (the
    // chase camera's FOV that grows with speed). The register holds the constant for the two
    // multiplies only.
    {0x001B7A3C, 8, {0xF3, 0x0F, 0x10, 0x15}, "chase camera FOV (0x5B77E0)"},
    {0x001B8973, 8, {0xF3, 0x0F, 0x10, 0x05}, "chase camera FOV (0x5B8350)"},
    // FUN_005CD460 and FUN_005CD7F0: camera +0x1E0 = param +0x34F0, or a blend of +0x34F0 and
    // +0x353C. In 0x5CD7F0 the register (xmm7) is also used once for a rotation; see kRollSite.
    {0x001CD679, 8, {0xF3, 0x0F, 0x10, 0x15}, "camera FOV blend (0x5CD460)"},
    {0x001CE4FF, 8, {0xF3, 0x0F, 0x10, 0x3D}, "camera FOV (0x5CD7F0)"},
    {0x001CE5B0, 8, {0xF3, 0x0F, 0x10, 0x3D}, "camera FOV blend (0x5CD7F0)"},
    // FUN_005D0520: the size of a camera effect's FOV kick (+0x88), per preset; 0x5D0970 adds
    // the kick to camera +0x1E0.
    {0x001D0598, 8, {0xF3, 0x0F, 0x59, 0x05}, "FOV kick (0x5D0520)"},
    {0x001D0623, 8, {0xF3, 0x0F, 0x59, 0x05}, "FOV kick (0x5D0520)"},
    {0x001D06A7, 8, {0xF3, 0x0F, 0x59, 0x05}, "FOV kick (0x5D0520)"},
    {0x001D072C, 8, {0xF3, 0x0F, 0x59, 0x05}, "FOV kick (0x5D0520)"},
    // FUN_00660030: the Lua table field "CameraFOV", stored at +0x1C of a 0x54-byte entry that
    // 0x7BC2D0 interpolates for the camera below.
    {0x002604B6, 8, {0xF3, 0x0F, 0x59, 0x05}, "Lua CameraFOV (0x660030)"},
    // The camera of 0x7B1A10: FOV at +0x88 easing to +0x8C, set with 0x5AB600 (0x7B3A53).
    {0x003B1A32, 6, {0xD8, 0x0D}, "eased camera FOV start (0x7B1A10)"},
    {0x003B44CD, 6, {0xD9, 0x05}, "eased camera FOV target (0x7B42A0)"},
    {0x003B4F02, 6, {0xD8, 0x0D}, "eased camera FOV target (0x7B4DF0)"},
    {0x003B50DD, 8, {0xF3, 0x0F, 0x10, 0x0D}, "eased camera FOV zoom-in (0x7B5070)"},
};
constexpr std::size_t kFovSiteCount = sizeof(kFovSites) / sizeof(kFovSites[0]);

// FUN_005CD7F0 multiplies a rotation (param +0x354C, turned with sin/cos into the camera's
// orientation) by the xmm7 that 0x1CE4FF/0x1CE5B0 load, so after those two sites move to the FOV
// scalar this multiply would scale too. It becomes a call to a stub that does the same two
// multiplies with the stock constant:
//   mulss xmm0, xmm7 ; mulss xmm6, xmm0   ->   call stub ; nop3
constexpr std::uint32_t kRollSiteRva = 0x001CE741;
constexpr std::uint8_t kRollSiteStock[8] = {0xF3, 0x0F, 0x59, 0xC7, 0xF3, 0x0F, 0x59, 0xF0};
constexpr std::uint8_t kRollSiteTail[3] = {0x0F, 0x1F, 0x00};

// The other 26 reads, which keep the stock constant: the cockpit gauges, rotations, angle
// limits and view cones. Listed so the test can tell when a read is not accounted for.
constexpr std::uint32_t kOtherReaderRvas[] = {
    0x00087DD7, 0x00087E71,             // 0x487C40: view cone test (cos of a half-angle)
    0x001B5110,                         // 0x5B4AF0: camera roll, param +0x3548 (sin/cos)
    0x001B699C,                         // 0x5B67A0: angle threshold, param +0x3360
    0x001B6D68,                         // 0x5B6D30: angle limits, params +0x33BC/+0x33C0
    0x001B7D29,                         // 0x5B7D00: rotation, param +0x33A0
    0x001B8165,                         // 0x5B7EE0: angle ratio and rotation, +0x339C/+0x3398
    0x001B83E3, 0x001B8A01,             // 0x5B8350: angle limits, params +0x33A0/+0x339C
    0x001BC848,                         // 0x5BC830: vehicle setup angles (Lua)
    0x001D3742, 0x001D4622, 0x001D61B2, // camera effects: rotation by +0xA8 (sin/cos)
    0x00295CB4,                         // 0x695C40: rotation (sin/cos)
    0x003E3BF1, 0x003E3C95,             // 0x7E3590: angle threshold, param +0x3398
    0x003E9CB1,                         // 0x7E9BD0: sin of an angle
    0x004525DA,                         // 0x852470: angle thresholds (16-bit degrees)
    0x004A2631,                         // 0x8A2610: cockpit needles (sweep x constant x input)
    0x004BE186,                         // 0x8BD9B0: angle, param +0x2E08
    0x008578BD,                         // 0xC578A0: angle wrap to radians
    0x008C83B4, 0x008C83FA, 0x008C8550, // 0xCC8380..: directions from angles (sin/cos)
    0x008C8898, 0x008C88D5,             // 0xCC8890: directions from angles (sin/cos)
};
constexpr std::size_t kOtherReaderCount = sizeof(kOtherReaderRvas) / sizeof(kOtherReaderRvas[0]);

// The instruction as the game has it (reading `constant_va`) or redirected (reading `scalar_va`).
inline void SiteBytes(const Site& site, std::uint32_t address, std::uint8_t* out)
{
    const std::size_t opcode_size = site.size - 4u;
    std::memcpy(out, site.opcode, opcode_size);
    std::memcpy(out + opcode_size, &address, sizeof(address));
}

} // namespace fovsites
