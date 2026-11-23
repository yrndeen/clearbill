// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title ClearbillRegistry
/// @notice Self-sovereign on-chain Payee Directory for Confirmation of Payee (CoP) on QDay Aevum Testnet.
/// @dev Payees publish their canonical display name and business tag directly; no admin keys or proxies.
contract ClearbillRegistry {
    struct PayeeProfile {
        string displayName;
        bytes32 displayNameHash;
        string businessTag;
        uint64 updatedAt;
        bool registered;
    }

    mapping(address => PayeeProfile) private _profiles;

    event PayeeProfileUpdated(
        address indexed payee,
        string displayName,
        bytes32 indexed displayNameHash,
        string businessTag,
        uint64 updatedAt
    );

    error EmptyDisplayName();
    error DisplayNameTooLong();
    error BusinessTagTooLong();

    uint256 public constant MAX_NAME_LEN = 80;
    uint256 public constant MAX_TAG_LEN = 40;

    /// @notice Registers or updates the caller's canonical Confirmation-of-Payee profile.
    function registerProfile(string calldata displayName, string calldata businessTag) external {
        bytes memory nameBytes = bytes(displayName);
        if (nameBytes.length == 0) revert EmptyDisplayName();
        if (nameBytes.length > MAX_NAME_LEN) revert DisplayNameTooLong();
        if (bytes(businessTag).length > MAX_TAG_LEN) revert BusinessTagTooLong();

        bytes32 nameHash = keccak256(nameBytes);
        uint64 ts = uint64(block.timestamp);

        _profiles[msg.sender] = PayeeProfile({
            displayName: displayName,
            displayNameHash: nameHash,
            businessTag: businessTag,
            updatedAt: ts,
            registered: true
        });

        emit PayeeProfileUpdated(msg.sender, displayName, nameHash, businessTag, ts);
    }

    function getProfile(address payee) external view returns (PayeeProfile memory) {
        return _profiles[payee];
    }

    /// @notice Returns true if payee has a registered profile whose display name exactly matches expectedName.
    function matchesRegisteredName(address payee, string calldata expectedName)
        external
        view
        returns (bool)
    {
        PayeeProfile storage p = _profiles[payee];
        if (!p.registered) return false;
        return p.displayNameHash == keccak256(bytes(expectedName));
    }
}
