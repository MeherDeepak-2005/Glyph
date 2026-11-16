#pragma once
#include <array>
#include <bit>
#include <cstddef>
#include <cstdint>
#include <span>
namespace kb {
inline std::array<std::byte,32> dictionarySHA256(std::span<const std::byte> bytes) {
    constexpr std::array<std::uint32_t,64> k{
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2};
    std::array<std::uint32_t,8> h{0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19};
    const auto blocks = (bytes.size()+9+63)/64;
    const auto bits = std::uint64_t(bytes.size())*8;
    for (std::size_t block=0; block<blocks; ++block) {
        std::array<std::uint32_t,64> w{};
        for (std::size_t j=0;j<64;++j) {
            auto at=block*64+j;
            std::uint32_t v=at<bytes.size()?std::to_integer<std::uint8_t>(bytes[at]):at==bytes.size()?128:0;
            if (at>=blocks*64-8) v=std::uint32_t((bits >> ((blocks*64-1-at)*8))&255);
            w[j/4]|=v<<(24-8*(j%4));
        }
        for (std::size_t j=16;j<64;++j) {
            auto a=w[j-15],b=w[j-2];
            w[j]=w[j-16]+(std::rotr(a,7)^std::rotr(a,18)^(a>>3))+w[j-7]+(std::rotr(b,17)^std::rotr(b,19)^(b>>10));
        }
        auto [a,b,c,d,e,f,g,z]=h;
        for (std::size_t j=0;j<64;++j) {
            auto t1=z+(std::rotr(e,6)^std::rotr(e,11)^std::rotr(e,25))+((e&f)^(~e&g))+k[j]+w[j];
            auto t2=(std::rotr(a,2)^std::rotr(a,13)^std::rotr(a,22))+((a&b)^(a&c)^(b&c));
            z=g;g=f;f=e;e=d+t1;d=c;c=b;b=a;a=t1+t2;
        }
        std::array<std::uint32_t,8> v{a,b,c,d,e,f,g,z};
        for(std::size_t j=0;j<8;++j)h[j]+=v[j];
    }
    std::array<std::byte,32> out{};
    for(std::size_t j=0;j<32;++j)out[j]=std::byte((h[j/4]>>(24-8*(j%4)))&255);
    return out;
}
}
