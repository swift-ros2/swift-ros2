/// PascalCase / acronym-aware snake_case, matching rosidl's file naming
/// (`convert_camel_case_to_lower_case_underscore`): `PointCloud2` -> `point_cloud2`,
/// `CompressedImage` -> `compressed_image`, `Imu` -> `imu`, and acronym runs break before
/// their trailing word — `MultiDOFJointState` -> `multi_dof_joint_state`, `TFMessage` ->
/// `tf_message`.
func snakeCase(_ pascal: String) -> String {
    var out = ""
    let chars = Array(pascal)
    for (i, ch) in chars.enumerated() {
        if ch.isUppercase {
            let prev = i > 0 ? chars[i - 1] : nil
            let next = i + 1 < chars.count ? chars[i + 1] : nil
            if let prev {
                // rosidl inserts "_" before an uppercase preceded by a lowercase/digit, and
                // before the last uppercase of an acronym run when a lowercase follows (DOF|Joint).
                if !prev.isUppercase {
                    out.append("_")
                } else if let next, next.isLowercase {
                    out.append("_")
                }
            }
            out.append(Character(ch.lowercased()))
        } else {
            out.append(ch)
        }
    }
    return out
}
