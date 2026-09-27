// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Minimal standard-alphabet base64 decoder for tests. Reverts on malformed input so a
///      corrupted tokenURI fails loudly instead of decoding to garbage.
library Base64Decoder {
    function decode(string memory input) internal pure returns (bytes memory) {
        bytes memory data = bytes(input);
        require(data.length % 4 == 0, "base64: length not a multiple of 4");
        if (data.length == 0) return "";

        uint256 padding = 0;
        if (data[data.length - 1] == "=") padding++;
        if (data[data.length - 2] == "=") padding++;

        uint256 outLen = (data.length / 4) * 3 - padding;
        bytes memory out = new bytes(outLen);

        uint256 j = 0;
        for (uint256 i = 0; i < data.length; i += 4) {
            uint256 n = (_value(data[i]) << 18) | (_value(data[i + 1]) << 12) | (_value(data[i + 2]) << 6)
                | _value(data[i + 3]);
            if (j < outLen) out[j++] = bytes1(uint8(n >> 16));
            if (j < outLen) out[j++] = bytes1(uint8(n >> 8));
            if (j < outLen) out[j++] = bytes1(uint8(n));
        }
        return out;
    }

    /// @dev Strip a known prefix (for example "data:application/json;base64,") and revert if absent.
    function stripPrefix(string memory input, string memory prefix) internal pure returns (string memory) {
        bytes memory data = bytes(input);
        bytes memory pre = bytes(prefix);
        require(data.length >= pre.length, "prefix: input too short");
        for (uint256 i = 0; i < pre.length; ++i) {
            require(data[i] == pre[i], "prefix: mismatch");
        }
        bytes memory rest = new bytes(data.length - pre.length);
        for (uint256 i = 0; i < rest.length; ++i) {
            rest[i] = data[pre.length + i];
        }
        return string(rest);
    }

    /// @dev Naive substring search; adequate for the few-kilobyte strings in these tests.
    function contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0) return true;
        if (n.length > h.length) return false;
        for (uint256 i = 0; i <= h.length - n.length; ++i) {
            bool matched = true;
            for (uint256 k = 0; k < n.length; ++k) {
                if (h[i + k] != n[k]) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
        return false;
    }

    function _value(bytes1 c) private pure returns (uint256) {
        uint8 u = uint8(c);
        if (u >= 65 && u <= 90) return u - 65; // A-Z
        if (u >= 97 && u <= 122) return u - 97 + 26; // a-z
        if (u >= 48 && u <= 57) return u - 48 + 52; // 0-9
        if (c == "+") return 62;
        if (c == "/") return 63;
        if (c == "=") return 0;
        revert("base64: invalid character");
    }
}
