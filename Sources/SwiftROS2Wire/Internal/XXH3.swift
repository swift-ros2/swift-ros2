// XXH3.swift
// XXH3 128-bit hash (default secret, seed 0), the function rmw_zenoh_cpp derives
// entity GIDs with.
//
// A port of rmw_zenoh_cpp's `simplified_xxhash3.cpp`, itself the portable scalar
// path of xxHash (https://github.com/Cyan4973/xxHash, BSD 2-Clause License,
// Copyright (C) 2012-2023 Yann Collet). Speed is not a concern: it hashes one
// liveliness token per entity.

/// The 128-bit XXH3 hash of a byte string, as `simplified_XXH3_128bits` returns it.
enum XXH3 {
    struct Hash128: Equatable {
        var low64: UInt64
        var high64: UInt64
    }

    static func hash128(_ input: [UInt8]) -> Hash128 {
        let len = input.count
        if len <= 16 { return len0to16(input) }
        if len <= 128 { return len17to128(input) }
        if len <= midsizeMax { return len129to240(input) }
        return hashLong(input)
    }

    // MARK: - Constants

    // `primeXXnN` is xxHash's `XXH_PRIMEXX_N`.

    private static let prime32n1: UInt64 = 0x9E37_79B1
    private static let prime32n2: UInt64 = 0x85EB_CA77
    private static let prime32n3: UInt64 = 0xC2B2_AE3D
    private static let prime64n1: UInt64 = 0x9E37_79B1_85EB_CA87
    private static let prime64n2: UInt64 = 0xC2B2_AE3D_27D4_EB4F
    private static let prime64n3: UInt64 = 0x1656_67B1_9E37_79F9
    private static let prime64n4: UInt64 = 0x85EB_CA77_C2B2_AE63
    private static let prime64n5: UInt64 = 0x27D4_EB2F_1656_67C5
    private static let primeMx1: UInt64 = 0x1656_6791_9E37_79F9
    private static let primeMx2: UInt64 = 0x9FB2_1C65_1E98_DF25

    private static let stripeLen = 64
    private static let secretConsumeRate = 8
    private static let accNb = 8
    private static let secretSizeMin = 136
    private static let midsizeMax = 240
    private static let midsizeStartOffset = 3
    private static let midsizeLastOffset = 17
    private static let secretLastAccStart = 7
    private static let secretMergeAccsStart = 11

    private static let secret: [UInt8] = [
        0xb8, 0xfe, 0x6c, 0x39, 0x23, 0xa4, 0x4b, 0xbe, 0x7c, 0x01, 0x81, 0x2c, 0xf7, 0x21, 0xad, 0x1c,
        0xde, 0xd4, 0x6d, 0xe9, 0x83, 0x90, 0x97, 0xdb, 0x72, 0x40, 0xa4, 0xa4, 0xb7, 0xb3, 0x67, 0x1f,
        0xcb, 0x79, 0xe6, 0x4e, 0xcc, 0xc0, 0xe5, 0x78, 0x82, 0x5a, 0xd0, 0x7d, 0xcc, 0xff, 0x72, 0x21,
        0xb8, 0x08, 0x46, 0x74, 0xf7, 0x43, 0x24, 0x8e, 0xe0, 0x35, 0x90, 0xe6, 0x81, 0x3a, 0x26, 0x4c,
        0x3c, 0x28, 0x52, 0xbb, 0x91, 0xc3, 0x00, 0xcb, 0x88, 0xd0, 0x65, 0x8b, 0x1b, 0x53, 0x2e, 0xa3,
        0x71, 0x64, 0x48, 0x97, 0xa2, 0x0d, 0xf9, 0x4e, 0x38, 0x19, 0xef, 0x46, 0xa9, 0xde, 0xac, 0xd8,
        0xa8, 0xfa, 0x76, 0x3f, 0xe3, 0x9c, 0x34, 0x3f, 0xf9, 0xdc, 0xbb, 0xc7, 0xc7, 0x0b, 0x4f, 0x1d,
        0x8a, 0x51, 0xe0, 0x4b, 0xcd, 0xb4, 0x59, 0x31, 0xc8, 0x9f, 0x7e, 0xc9, 0xd9, 0x78, 0x73, 0x64,
        0xea, 0xc5, 0xac, 0x83, 0x34, 0xd3, 0xeb, 0xc3, 0xc5, 0x81, 0xa0, 0xff, 0xfa, 0x13, 0x63, 0xeb,
        0x17, 0x0d, 0xdd, 0x51, 0xb7, 0xf0, 0xda, 0x49, 0xd3, 0x16, 0x55, 0x26, 0x29, 0xd4, 0x68, 0x9e,
        0x2b, 0x16, 0xbe, 0x58, 0x7d, 0x47, 0xa1, 0xfc, 0x8f, 0xf8, 0xb8, 0xd1, 0x7a, 0xd0, 0x31, 0xce,
        0x45, 0xcb, 0x3a, 0x8f, 0x95, 0x16, 0x04, 0x28, 0xaf, 0xd7, 0xfb, 0xca, 0xbb, 0x4b, 0x40, 0x7e,
    ]

    // MARK: - Primitives

    private static func readLE64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 { value |= UInt64(bytes[offset + i]) << (8 * UInt64(i)) }
        return value
    }

    private static func readLE32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<4 { value |= UInt32(bytes[offset + i]) << (8 * UInt32(i)) }
        return value
    }

    private static func mult32to64(_ x: UInt64, _ y: UInt64) -> UInt64 {
        (x & 0xFFFF_FFFF) &* (y & 0xFFFF_FFFF)
    }

    private static func mult64to128(_ lhs: UInt64, _ rhs: UInt64) -> Hash128 {
        let product = lhs.multipliedFullWidth(by: rhs)
        return Hash128(low64: product.low, high64: product.high)
    }

    private static func mul128Fold64(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let product = mult64to128(lhs, rhs)
        return product.low64 ^ product.high64
    }

    private static func xorshift64(_ v: UInt64, _ shift: UInt64) -> UInt64 {
        v ^ (v >> shift)
    }

    private static func avalanche(_ h: UInt64) -> UInt64 {
        var h64 = xorshift64(h, 37)
        h64 = h64 &* primeMx1
        return xorshift64(h64, 32)
    }

    private static func xxh64Avalanche(_ h: UInt64) -> UInt64 {
        var hash = h
        hash ^= hash >> 33
        hash = hash &* prime64n2
        hash ^= hash >> 29
        hash = hash &* prime64n3
        hash ^= hash >> 32
        return hash
    }

    // MARK: - 0 to 16 bytes

    private static func len0to16(_ input: [UInt8]) -> Hash128 {
        let len = input.count
        if len > 8 { return len9to16(input) }
        if len >= 4 { return len4to8(input) }
        if len > 0 { return len1to3(input) }
        let bitflipl = readLE64(secret, 64) ^ readLE64(secret, 72)
        let bitfliph = readLE64(secret, 80) ^ readLE64(secret, 88)
        return Hash128(low64: xxh64Avalanche(bitflipl), high64: xxh64Avalanche(bitfliph))
    }

    private static func len1to3(_ input: [UInt8]) -> Hash128 {
        let len = input.count
        let c1 = UInt32(input[0])
        let c2 = UInt32(input[len >> 1])
        let c3 = UInt32(input[len - 1])
        let combinedl = (c1 << 16) | (c2 << 24) | c3 | (UInt32(len) << 8)
        let swapped = combinedl.byteSwapped
        let combinedh = (swapped << 13) | (swapped >> 19)
        let bitflipl = UInt64(readLE32(secret, 0) ^ readLE32(secret, 4))
        let bitfliph = UInt64(readLE32(secret, 8) ^ readLE32(secret, 12))
        return Hash128(
            low64: xxh64Avalanche(UInt64(combinedl) ^ bitflipl),
            high64: xxh64Avalanche(UInt64(combinedh) ^ bitfliph))
    }

    private static func len4to8(_ input: [UInt8]) -> Hash128 {
        let len = input.count
        let inputLo = UInt64(readLE32(input, 0))
        let inputHi = UInt64(readLE32(input, len - 4))
        let input64 = inputLo &+ (inputHi << 32)
        let bitflip = readLE64(secret, 16) ^ readLE64(secret, 24)
        let keyed = input64 ^ bitflip

        var m128 = mult64to128(keyed, prime64n1 &+ (UInt64(len) << 2))
        m128.high64 = m128.high64 &+ (m128.low64 << 1)
        m128.low64 ^= (m128.high64 >> 3)
        m128.low64 = xorshift64(m128.low64, 35)
        m128.low64 = m128.low64 &* primeMx2
        m128.low64 = xorshift64(m128.low64, 28)
        m128.high64 = avalanche(m128.high64)
        return m128
    }

    private static func len9to16(_ input: [UInt8]) -> Hash128 {
        let len = input.count
        let bitflipl = readLE64(secret, 32) ^ readLE64(secret, 40)
        let bitfliph = readLE64(secret, 48) ^ readLE64(secret, 56)
        let inputLo = readLE64(input, 0)
        var inputHi = readLE64(input, len - 8)
        var m128 = mult64to128(inputLo ^ inputHi ^ bitflipl, prime64n1)
        m128.low64 = m128.low64 &+ (UInt64(len - 1) << 54)
        inputHi ^= bitfliph
        m128.high64 = m128.high64 &+ inputHi &+ mult32to64(UInt64(UInt32(truncatingIfNeeded: inputHi)), prime32n2 - 1)
        m128.low64 ^= m128.high64.byteSwapped

        var h128 = mult64to128(m128.low64, prime64n2)
        h128.high64 = h128.high64 &+ (m128.high64 &* prime64n2)
        h128.low64 = avalanche(h128.low64)
        h128.high64 = avalanche(h128.high64)
        return h128
    }

    // MARK: - 17 to 240 bytes

    private static func mix16B(_ input: [UInt8], _ offset: Int, _ secretOffset: Int) -> UInt64 {
        mul128Fold64(
            readLE64(input, offset) ^ readLE64(secret, secretOffset),
            readLE64(input, offset + 8) ^ readLE64(secret, secretOffset + 8))
    }

    private static func mix32B(
        _ acc: Hash128, _ input: [UInt8], _ offset1: Int, _ offset2: Int, _ secretOffset: Int
    ) -> Hash128 {
        var acc = acc
        acc.low64 = acc.low64 &+ mix16B(input, offset1, secretOffset)
        acc.low64 ^= readLE64(input, offset2) &+ readLE64(input, offset2 + 8)
        acc.high64 = acc.high64 &+ mix16B(input, offset2, secretOffset + 16)
        acc.high64 ^= readLE64(input, offset1) &+ readLE64(input, offset1 + 8)
        return acc
    }

    private static func finish(_ acc: Hash128, len: Int) -> Hash128 {
        let low = acc.low64 &+ acc.high64
        let high = (acc.low64 &* prime64n1) &+ (acc.high64 &* prime64n4) &+ (UInt64(len) &* prime64n2)
        return Hash128(low64: avalanche(low), high64: 0 &- avalanche(high))
    }

    private static func len17to128(_ input: [UInt8]) -> Hash128 {
        let len = input.count
        var acc = Hash128(low64: UInt64(len) &* prime64n1, high64: 0)
        if len > 32 {
            if len > 64 {
                if len > 96 {
                    acc = mix32B(acc, input, 48, len - 64, 96)
                }
                acc = mix32B(acc, input, 32, len - 48, 64)
            }
            acc = mix32B(acc, input, 16, len - 32, 32)
        }
        acc = mix32B(acc, input, 0, len - 16, 0)
        return finish(acc, len: len)
    }

    private static func len129to240(_ input: [UInt8]) -> Hash128 {
        let len = input.count
        var acc = Hash128(low64: UInt64(len) &* prime64n1, high64: 0)
        var i = 32
        while i < 160 {
            acc = mix32B(acc, input, i - 32, i - 16, i - 32)
            i += 32
        }
        acc.low64 = avalanche(acc.low64)
        acc.high64 = avalanche(acc.high64)
        i = 160
        while i <= len {
            acc = mix32B(acc, input, i - 32, i - 16, midsizeStartOffset + i - 160)
            i += 32
        }
        acc = mix32B(acc, input, len - 16, len - 32, secretSizeMin - midsizeLastOffset - 16)
        return finish(acc, len: len)
    }

    // MARK: - More than 240 bytes

    private static func accumulate512(_ acc: inout [UInt64], _ input: [UInt8], _ offset: Int, _ secretOffset: Int) {
        for lane in 0..<accNb {
            let dataVal = readLE64(input, offset + lane * 8)
            let dataKey = dataVal ^ readLE64(secret, secretOffset + lane * 8)
            acc[lane ^ 1] = acc[lane ^ 1] &+ dataVal
            acc[lane] = mult32to64(dataKey, dataKey >> 32) &+ acc[lane]
        }
    }

    private static func scrambleAcc(_ acc: inout [UInt64], _ secretOffset: Int) {
        for lane in 0..<accNb {
            var acc64 = xorshift64(acc[lane], 47)
            acc64 ^= readLE64(secret, secretOffset + lane * 8)
            acc[lane] = acc64 &* prime32n1
        }
    }

    private static func mergeAccs(_ acc: [UInt64], _ secretOffset: Int, start: UInt64) -> UInt64 {
        var result = start
        for i in 0..<4 {
            result =
                result
                &+ mul128Fold64(
                    acc[2 * i] ^ readLE64(secret, secretOffset + 16 * i),
                    acc[2 * i + 1] ^ readLE64(secret, secretOffset + 16 * i + 8))
        }
        return avalanche(result)
    }

    private static func hashLong(_ input: [UInt8]) -> Hash128 {
        let len = input.count
        var acc: [UInt64] = [prime32n3, prime64n1, prime64n2, prime64n3, prime64n4, prime32n2, prime64n5, prime32n1]
        let stripesPerBlock = (secret.count - stripeLen) / secretConsumeRate
        let blockLen = stripeLen * stripesPerBlock
        let blocks = (len - 1) / blockLen
        for n in 0..<blocks {
            for s in 0..<stripesPerBlock {
                accumulate512(&acc, input, n * blockLen + s * stripeLen, s * secretConsumeRate)
            }
            scrambleAcc(&acc, secret.count - stripeLen)
        }
        let stripes = ((len - 1) - blockLen * blocks) / stripeLen
        for s in 0..<stripes {
            accumulate512(&acc, input, blocks * blockLen + s * stripeLen, s * secretConsumeRate)
        }
        accumulate512(&acc, input, len - stripeLen, secret.count - stripeLen - secretLastAccStart)

        return Hash128(
            low64: mergeAccs(acc, secretMergeAccsStart, start: UInt64(len) &* prime64n1),
            high64: mergeAccs(
                acc, secret.count - accNb * 8 - secretMergeAccsStart, start: ~(UInt64(len) &* prime64n2)))
    }
}
