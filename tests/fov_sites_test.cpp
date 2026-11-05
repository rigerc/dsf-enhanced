// FOVScaling's site table (src/fov_sites.h). Built and run by build.ps1. Without arguments it checks
// the table itself. With the path of Driver.exe 1.04 it also reads the file (never writes it) and
// checks that every instruction reading the degrees-to-radians constant is in the table, either
// as a FOV site or as another reader, and that each FOV site's bytes are the game's:
//   build\fov_sites_test.exe "D:\Games\Driver San Francisco\Driver.exe"
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iterator>
#include <set>
#include <vector>
#include "../src/fov_sites.h"

namespace {

int g_failures = 0;

#define CHECK(cond) do { if (!(cond)) { std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); ++g_failures; } } while (0)

std::uint32_t Read32(const std::vector<std::uint8_t>& data, std::size_t offset)
{
    std::uint32_t value = 0;
    if (offset + 4 <= data.size()) {
        std::memcpy(&value, data.data() + offset, sizeof(value));
    }
    return value;
}

std::uint16_t Read16(const std::vector<std::uint8_t>& data, std::size_t offset)
{
    std::uint16_t value = 0;
    if (offset + 2 <= data.size()) {
        std::memcpy(&value, data.data() + offset, sizeof(value));
    }
    return value;
}

void CheckTable()
{
    using namespace fovsites;
    std::set<std::uint32_t> starts;
    for (const Site& site : kFovSites) {
        CHECK(site.size == 6 || site.size == 8);
        CHECK(starts.insert(site.rva).second);
        if (site.size == 8) {
            // movss xmmN, [abs] (F3 0F 10 modrm) or mulss xmm0, [abs] (F3 0F 59 05)
            CHECK(site.opcode[0] == 0xF3 && site.opcode[1] == 0x0F);
            CHECK(site.opcode[2] == 0x10 || site.opcode[2] == 0x59);
            CHECK((site.opcode[3] & 0xC7) == 0x05);
        } else {
            // fld / fmul dword [abs]
            CHECK(site.opcode[0] == 0xD8 || site.opcode[0] == 0xD9);
            CHECK((site.opcode[1] & 0xC7) == 0x05);
        }
        CHECK(site.reader != nullptr && site.reader[0] != '\0');

        std::uint8_t bytes[8] = {};
        SiteBytes(site, 0x12345678u, bytes);
        CHECK(std::memcmp(bytes, site.opcode, site.size - 4u) == 0);
        CHECK(Read32(std::vector<std::uint8_t>(bytes, bytes + site.size), site.size - 4u) == 0x12345678u);
    }
    for (std::uint32_t rva : kOtherReaderRvas) {
        CHECK(starts.insert(rva).second);
    }
    // The stub replaces two instructions: 8 bytes, a 5-byte call and a 3-byte nop.
    CHECK(sizeof(kRollSiteStock) == 5 + sizeof(kRollSiteTail));
    CHECK(kFovSiteCount == 19);
    CHECK(kOtherReaderCount == 26);
}

// Maps the PE file by section so RVAs index it.
bool LoadImage(const char* path, std::vector<std::uint8_t>* image, std::uint32_t* image_base)
{
    std::ifstream file(path, std::ios::binary);
    if (!file) {
        std::printf("FAIL cannot open %s\n", path);
        return false;
    }
    const std::vector<std::uint8_t> raw((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
    const std::uint32_t pe = Read32(raw, 0x3C);
    if (Read32(raw, pe) != 0x00004550u || Read16(raw, pe + 4) != 0x014C) {
        std::printf("FAIL %s is not a 32-bit PE file\n", path);
        return false;
    }
    const std::uint16_t sections = Read16(raw, pe + 6);
    const std::uint16_t optional_size = Read16(raw, pe + 20);
    const std::size_t optional = pe + 24;
    *image_base = Read32(raw, optional + 28);
    const std::uint32_t image_size = Read32(raw, optional + 56);
    image->assign(image_size, 0);
    const std::size_t table = optional + optional_size;
    for (std::uint16_t i = 0; i < sections; ++i) {
        const std::size_t header = table + i * 40u;
        const std::uint32_t virtual_address = Read32(raw, header + 12);
        const std::uint32_t raw_size = Read32(raw, header + 16);
        const std::uint32_t raw_offset = Read32(raw, header + 20);
        if (raw_offset + raw_size > raw.size() || virtual_address + raw_size > image->size()) {
            std::printf("FAIL section %u lies outside the file or image\n", i);
            return false;
        }
        std::memcpy(image->data() + virtual_address, raw.data() + raw_offset, raw_size);
    }
    return true;
}

void CheckGame(const char* path)
{
    using namespace fovsites;
    std::vector<std::uint8_t> image;
    std::uint32_t image_base = 0;
    if (!LoadImage(path, &image, &image_base)) {
        ++g_failures;
        return;
    }
    CHECK(image_base == kImageBase);
    CHECK(Read32(image, kDegreesToRadiansRva) == kDegreesToRadiansBits);
    const std::uint32_t constant_va = image_base + kDegreesToRadiansRva;

    // Every place the image holds the constant's address.
    std::set<std::uint32_t> found;
    for (std::size_t offset = 0; offset + 4 <= image.size(); ++offset) {
        if (Read32(image, offset) == constant_va) {
            found.insert(static_cast<std::uint32_t>(offset));
        }
    }

    std::set<std::uint32_t> accounted;
    for (const Site& site : kFovSites) {
        std::uint8_t expected[8] = {};
        SiteBytes(site, constant_va, expected);
        const bool match = std::memcmp(image.data() + site.rva, expected, site.size) == 0;
        if (!match) {
            std::printf("FAIL FOV site RVA 0x%08X (%s) differs from the game\n", site.rva, site.reader);
            ++g_failures;
        }
        accounted.insert(site.rva + site.size - 4u);
    }
    for (std::uint32_t rva : kOtherReaderRvas) {
        // F3 0F xx modrm [abs] or D8/D9 modrm [abs]
        const std::uint8_t* at = image.data() + rva;
        const std::uint32_t operand = (at[0] == 0xF3 && at[1] == 0x0F) ? rva + 4 : rva + 2;
        if (Read32(image, operand) != constant_va) {
            std::printf("FAIL other reader RVA 0x%08X does not read the constant\n", rva);
            ++g_failures;
        }
        accounted.insert(operand);
    }
    for (std::uint32_t offset : found) {
        if (accounted.count(offset) == 0) {
            std::printf("FAIL RVA 0x%08X holds the constant's address and is in no list\n", offset);
            ++g_failures;
        }
    }
    CHECK(found.size() == kFovSiteCount + kOtherReaderCount);
    CHECK(std::memcmp(image.data() + kRollSiteRva, kRollSiteStock, sizeof(kRollSiteStock)) == 0);
    std::printf("Driver.exe: %u reads of 0x%08X, %u FOV sites, %u others\n",
        static_cast<unsigned>(found.size()), constant_va,
        static_cast<unsigned>(kFovSiteCount), static_cast<unsigned>(kOtherReaderCount));
}

} // namespace

int main(int argc, char** argv)
{
    CheckTable();
    for (int i = 1; i < argc; ++i) {
        CheckGame(argv[i]);
    }
    if (g_failures != 0) {
        std::printf("fov_sites_test: %d failure(s)\n", g_failures);
        return 1;
    }
    std::printf("fov_sites_test: ok\n");
    return 0;
}
