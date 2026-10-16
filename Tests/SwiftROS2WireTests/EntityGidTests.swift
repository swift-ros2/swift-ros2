// EntityGidTests.swift
// The entity GID rmw_zenoh_cpp derives from a liveliness token.

import XCTest

@testable import SwiftROS2Wire

final class EntityGidTests: XCTestCase {
    /// XXH3 128-bit (default secret, seed 0) of `(i * 7 + 3) % 256` for `i` in
    /// `0..<length`, from the Python `xxhash` 3.5.0 package (`xxh3_128_intdigest`).
    /// The lengths cover every branch: 0, 1–3, 4–8, 9–16, 17–128, 129–240 and longer.
    func testXXH3MatchesTheReferenceImplementation() {
        let vectors: [(length: Int, low64: UInt64, high64: UInt64)] = [
            (0, 0x6001_c324_468d_497f, 0x99aa_06d3_0147_98d8),
            (1, 0x13e6_08bc_156d_efed, 0x22bb_b76b_211a_39ba),
            (2, 0x1c90_74b9_3943_b86c, 0xa6b9_dd53_b144_8722),
            (3, 0xa908_8dda_485b_481c, 0xce31_763c_bf82_45a5),
            (4, 0x788a_6091_54b0_fe20, 0x4719_7970_5907_46b1),
            (7, 0x7af1_e487_627d_d4bc, 0xa051_eefb_8df8_740e),
            (8, 0x3cd0_24e3_d63a_1588, 0xe3bc_8a5f_4617_1555),
            (9, 0xeafa_b1c7_f123_109f, 0xc72c_8824_7a9a_56d7),
            (15, 0xc30b_2971_5d72_82a3, 0x68f7_5783_c1d1_a650),
            (16, 0x60d7_5c5e_47d4_0a24, 0xce0b_9647_ab24_f884),
            (17, 0xeeed_7654_312a_26d7, 0xbfd3_27ed_cc2f_bd12),
            (31, 0x262d_eca0_4334_1a5b, 0x670e_e2d7_9d25_52f8),
            (32, 0xd761_fd22_e8ad_5262, 0x4f13_0f27_ab6b_af45),
            (33, 0x4193_c535_612a_c940, 0xd15b_2729_93d9_830f),
            (64, 0xaa54_9d72_c69c_d267, 0xfed9_53fe_6a8b_2b63),
            (65, 0x4362_2ea0_1271_a860, 0x9f55_8090_3f79_bec3),
            (96, 0x0ab6_3bcf_bc90_7abb, 0x2a35_0495_986d_b37a),
            (97, 0x8d17_d1af_ec22_619e, 0x3ffe_2e0f_781d_623c),
            (128, 0xc580_008b_6c92_ac53, 0x1b19_62a0_96ba_c78b),
            (129, 0xbd91_ce7a_ce4d_385b, 0x293e_4968_c461_9023),
            (160, 0x0e29_8e02_860a_8fd0, 0xd715_19a3_7cb7_5ab6),
            (192, 0x4ed9_9876_4c52_1fac, 0x5b00_3778_4bee_7fc6),
            (200, 0x3801_42cd_d584_3bbd, 0x3220_0a52_a918_beaf),
            (239, 0x49fb_6a0a_5210_e031, 0xcb7a_8da5_7ad8_3292),
            (240, 0x04e0_b5f0_34be_e80b, 0xad46_c102_1b07_6bc7),
            (241, 0x8bea_dd3a_8874_fe17, 0xac6c_3492_c3d6_b45d),
            (500, 0xb8bc_3e56_83ce_226a, 0xd4d7_627f_9740_1d3d),
            (1024, 0x9b81_661c_641c_72b1, 0x18bc_0eac_a9a3_3636),
            (1025, 0x806c_2072_ed71_3576, 0xbf44_7251_cfa9_8d7c),
            (2049, 0x55ae_d42c_9f15_54b6, 0xfc9d_a734_0154_dc6c),
        ]
        for vector in vectors {
            let input = (0..<vector.length).map { UInt8(($0 * 7 + 3) % 256) }
            XCTAssertEqual(
                XXH3.hash128(input), XXH3.Hash128(low64: vector.low64, high64: vector.high64),
                "length \(vector.length)")
        }
    }

    /// The publisher of an rclpy node on Lyrical (rmw_zenoh_cpp 0.10.6): its token, read
    /// with a liveliness query, and the GID `ros2 topic info -v /e2e_s3/chatter` showed.
    func testGidMatchesTheGidRmwZenohShowsForItsToken() {
        let token =
            "@ros2_lv/123/9aa0e28b80becd1ebd89d9110038ec5f/0/10/MP/%/%e2e_s3/ref_node/%e2e_s3%chatter/"
            + "std_msgs::msg::dds_::String_/RIHS01_df668c740482bbd48fb39d76a70dfd4bd59db1288021743503259e948f6b1a18/"
            + "::,10:,:,:,,"
        XCTAssertEqual(
            ZenohWireCodec.entityGid(livelinessToken: token),
            [
                0x30, 0x58, 0xd2, 0x30, 0x8d, 0x3d, 0xd3, 0x79, 0xa2, 0xb6, 0x22, 0x9c, 0x03, 0xba, 0xbc, 0xdb,
            ])
    }
}
