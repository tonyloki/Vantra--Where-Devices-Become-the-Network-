// This is a generated file - do not edit.
//
// Generated from vantra_message.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports
// ignore_for_file: unused_import

import 'dart:convert' as $convert;
import 'dart:core' as $core;
import 'dart:typed_data' as $typed_data;

@$core.Deprecated('Use capabilityDescriptor instead')
const Capability$json = {
  '1': 'Capability',
  '2': [
    {'1': 'CAPABILITY_UNSPECIFIED', '2': 0},
    {'1': 'CAPABILITY_TEXT', '2': 1},
    {'1': 'CAPABILITY_IMAGE', '2': 2},
    {'1': 'CAPABILITY_AUDIO', '2': 3},
    {'1': 'CAPABILITY_VIDEO', '2': 4},
    {'1': 'CAPABILITY_FILE', '2': 5},
    {'1': 'CAPABILITY_GROUP', '2': 6},
  ],
};

/// Descriptor for `Capability`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List capabilityDescriptor = $convert.base64Decode(
    'CgpDYXBhYmlsaXR5EhoKFkNBUEFCSUxJVFlfVU5TUEVDSUZJRUQQABITCg9DQVBBQklMSVRZX1'
    'RFWFQQARIUChBDQVBBQklMSVRZX0lNQUdFEAISFAoQQ0FQQUJJTElUWV9BVURJTxADEhQKEENB'
    'UEFCSUxJVFlfVklERU8QBBITCg9DQVBBQklMSVRZX0ZJTEUQBRIUChBDQVBBQklMSVRZX0dST1'
    'VQEAY=');

@$core.Deprecated('Use deliveryStatusDescriptor instead')
const DeliveryStatus$json = {
  '1': 'DeliveryStatus',
  '2': [
    {'1': 'DELIVERY_UNSPECIFIED', '2': 0},
    {'1': 'DELIVERY_DELIVERED', '2': 1},
  ],
};

/// Descriptor for `DeliveryStatus`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List deliveryStatusDescriptor = $convert.base64Decode(
    'Cg5EZWxpdmVyeVN0YXR1cxIYChRERUxJVkVSWV9VTlNQRUNJRklFRBAAEhYKEkRFTElWRVJZX0'
    'RFTElWRVJFRBAB');

@$core.Deprecated('Use vantraWireEnvelopeDescriptor instead')
const VantraWireEnvelope$json = {
  '1': 'VantraWireEnvelope',
  '2': [
    {'1': 'protocol_version', '3': 1, '4': 1, '5': 13, '10': 'protocolVersion'},
    {
      '1': 'handshake',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.vantra.protocol.IdentitySecurePayload',
      '9': 0,
      '10': 'handshake'
    },
    {
      '1': 'encrypted_message',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.vantra.protocol.EncryptedEnvelope',
      '9': 0,
      '10': 'encryptedMessage'
    },
    {
      '1': 'error',
      '3': 4,
      '4': 1,
      '5': 11,
      '6': '.vantra.protocol.ProtocolErrorPayload',
      '9': 0,
      '10': 'error'
    },
  ],
  '8': [
    {'1': 'payload'},
  ],
};

/// Descriptor for `VantraWireEnvelope`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List vantraWireEnvelopeDescriptor = $convert.base64Decode(
    'ChJWYW50cmFXaXJlRW52ZWxvcGUSKQoQcHJvdG9jb2xfdmVyc2lvbhgBIAEoDVIPcHJvdG9jb2'
    'xWZXJzaW9uEkYKCWhhbmRzaGFrZRgCIAEoCzImLnZhbnRyYS5wcm90b2NvbC5JZGVudGl0eVNl'
    'Y3VyZVBheWxvYWRIAFIJaGFuZHNoYWtlElEKEWVuY3J5cHRlZF9tZXNzYWdlGAMgASgLMiIudm'
    'FudHJhLnByb3RvY29sLkVuY3J5cHRlZEVudmVsb3BlSABSEGVuY3J5cHRlZE1lc3NhZ2USPQoF'
    'ZXJyb3IYBCABKAsyJS52YW50cmEucHJvdG9jb2wuUHJvdG9jb2xFcnJvclBheWxvYWRIAFIFZX'
    'Jyb3JCCQoHcGF5bG9hZA==');

@$core.Deprecated('Use identitySecurePayloadDescriptor instead')
const IdentitySecurePayload$json = {
  '1': 'IdentitySecurePayload',
  '2': [
    {'1': 'peer_id', '3': 1, '4': 1, '5': 9, '10': 'peerId'},
    {'1': 'display_name', '3': 2, '4': 1, '5': 9, '10': 'displayName'},
    {
      '1': 'identity_public_key',
      '3': 3,
      '4': 1,
      '5': 12,
      '10': 'identityPublicKey'
    },
    {
      '1': 'ephemeral_public_key',
      '3': 4,
      '4': 1,
      '5': 12,
      '10': 'ephemeralPublicKey'
    },
    {'1': 'signature', '3': 5, '4': 1, '5': 12, '10': 'signature'},
    {
      '1': 'min_supported_version',
      '3': 6,
      '4': 1,
      '5': 13,
      '10': 'minSupportedVersion'
    },
    {
      '1': 'max_supported_version',
      '3': 7,
      '4': 1,
      '5': 13,
      '10': 'maxSupportedVersion'
    },
    {
      '1': 'supported_capabilities',
      '3': 8,
      '4': 3,
      '5': 14,
      '6': '.vantra.protocol.Capability',
      '10': 'supportedCapabilities'
    },
  ],
};

/// Descriptor for `IdentitySecurePayload`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List identitySecurePayloadDescriptor = $convert.base64Decode(
    'ChVJZGVudGl0eVNlY3VyZVBheWxvYWQSFwoHcGVlcl9pZBgBIAEoCVIGcGVlcklkEiEKDGRpc3'
    'BsYXlfbmFtZRgCIAEoCVILZGlzcGxheU5hbWUSLgoTaWRlbnRpdHlfcHVibGljX2tleRgDIAEo'
    'DFIRaWRlbnRpdHlQdWJsaWNLZXkSMAoUZXBoZW1lcmFsX3B1YmxpY19rZXkYBCABKAxSEmVwaG'
    'VtZXJhbFB1YmxpY0tleRIcCglzaWduYXR1cmUYBSABKAxSCXNpZ25hdHVyZRIyChVtaW5fc3Vw'
    'cG9ydGVkX3ZlcnNpb24YBiABKA1SE21pblN1cHBvcnRlZFZlcnNpb24SMgoVbWF4X3N1cHBvcn'
    'RlZF92ZXJzaW9uGAcgASgNUhNtYXhTdXBwb3J0ZWRWZXJzaW9uElIKFnN1cHBvcnRlZF9jYXBh'
    'YmlsaXRpZXMYCCADKA4yGy52YW50cmEucHJvdG9jb2wuQ2FwYWJpbGl0eVIVc3VwcG9ydGVkQ2'
    'FwYWJpbGl0aWVz');

@$core.Deprecated('Use encryptedEnvelopeDescriptor instead')
const EncryptedEnvelope$json = {
  '1': 'EncryptedEnvelope',
  '2': [
    {'1': 'message_id', '3': 1, '4': 1, '5': 9, '10': 'messageId'},
    {'1': 'session_id', '3': 2, '4': 1, '5': 9, '10': 'sessionId'},
    {'1': 'sequence', '3': 3, '4': 1, '5': 4, '10': 'sequence'},
    {'1': 'nonce', '3': 4, '4': 1, '5': 12, '10': 'nonce'},
    {'1': 'ciphertext', '3': 5, '4': 1, '5': 12, '10': 'ciphertext'},
    {'1': 'mac', '3': 6, '4': 1, '5': 12, '10': 'mac'},
  ],
};

/// Descriptor for `EncryptedEnvelope`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List encryptedEnvelopeDescriptor = $convert.base64Decode(
    'ChFFbmNyeXB0ZWRFbnZlbG9wZRIdCgptZXNzYWdlX2lkGAEgASgJUgltZXNzYWdlSWQSHQoKc2'
    'Vzc2lvbl9pZBgCIAEoCVIJc2Vzc2lvbklkEhoKCHNlcXVlbmNlGAMgASgEUghzZXF1ZW5jZRIU'
    'CgVub25jZRgEIAEoDFIFbm9uY2USHgoKY2lwaGVydGV4dBgFIAEoDFIKY2lwaGVydGV4dBIQCg'
    'NtYWMYBiABKAxSA21hYw==');

@$core.Deprecated('Use vantraPlaintextDescriptor instead')
const VantraPlaintext$json = {
  '1': 'VantraPlaintext',
  '2': [
    {'1': 'message_id', '3': 1, '4': 1, '5': 9, '10': 'messageId'},
    {'1': 'session_id', '3': 2, '4': 1, '5': 9, '10': 'sessionId'},
    {'1': 'sequence', '3': 3, '4': 1, '5': 4, '10': 'sequence'},
    {'1': 'timestamp_ms', '3': 4, '4': 1, '5': 3, '10': 'timestampMs'},
    {'1': 'sender_id', '3': 5, '4': 1, '5': 9, '10': 'senderId'},
    {'1': 'receiver_id', '3': 6, '4': 1, '5': 9, '10': 'receiverId'},
    {
      '1': 'text',
      '3': 7,
      '4': 1,
      '5': 11,
      '6': '.vantra.protocol.TextBody',
      '9': 0,
      '10': 'text'
    },
    {
      '1': 'ack',
      '3': 8,
      '4': 1,
      '5': 11,
      '6': '.vantra.protocol.AckBody',
      '9': 0,
      '10': 'ack'
    },
    {
      '1': 'capabilities_exchange',
      '3': 9,
      '4': 1,
      '5': 11,
      '6': '.vantra.protocol.CapabilitiesExchange',
      '9': 0,
      '10': 'capabilitiesExchange'
    },
  ],
  '8': [
    {'1': 'body'},
  ],
};

/// Descriptor for `VantraPlaintext`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List vantraPlaintextDescriptor = $convert.base64Decode(
    'Cg9WYW50cmFQbGFpbnRleHQSHQoKbWVzc2FnZV9pZBgBIAEoCVIJbWVzc2FnZUlkEh0KCnNlc3'
    'Npb25faWQYAiABKAlSCXNlc3Npb25JZBIaCghzZXF1ZW5jZRgDIAEoBFIIc2VxdWVuY2USIQoM'
    'dGltZXN0YW1wX21zGAQgASgDUgt0aW1lc3RhbXBNcxIbCglzZW5kZXJfaWQYBSABKAlSCHNlbm'
    'RlcklkEh8KC3JlY2VpdmVyX2lkGAYgASgJUgpyZWNlaXZlcklkEi8KBHRleHQYByABKAsyGS52'
    'YW50cmEucHJvdG9jb2wuVGV4dEJvZHlIAFIEdGV4dBIsCgNhY2sYCCABKAsyGC52YW50cmEucH'
    'JvdG9jb2wuQWNrQm9keUgAUgNhY2sSXAoVY2FwYWJpbGl0aWVzX2V4Y2hhbmdlGAkgASgLMiUu'
    'dmFudHJhLnByb3RvY29sLkNhcGFiaWxpdGllc0V4Y2hhbmdlSABSFGNhcGFiaWxpdGllc0V4Y2'
    'hhbmdlQgYKBGJvZHk=');

@$core.Deprecated('Use capabilitiesExchangeDescriptor instead')
const CapabilitiesExchange$json = {
  '1': 'CapabilitiesExchange',
  '2': [
    {
      '1': 'min_supported_version',
      '3': 1,
      '4': 1,
      '5': 13,
      '10': 'minSupportedVersion'
    },
    {
      '1': 'max_supported_version',
      '3': 2,
      '4': 1,
      '5': 13,
      '10': 'maxSupportedVersion'
    },
    {
      '1': 'supported_capabilities',
      '3': 3,
      '4': 3,
      '5': 14,
      '6': '.vantra.protocol.Capability',
      '10': 'supportedCapabilities'
    },
  ],
};

/// Descriptor for `CapabilitiesExchange`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List capabilitiesExchangeDescriptor = $convert.base64Decode(
    'ChRDYXBhYmlsaXRpZXNFeGNoYW5nZRIyChVtaW5fc3VwcG9ydGVkX3ZlcnNpb24YASABKA1SE2'
    '1pblN1cHBvcnRlZFZlcnNpb24SMgoVbWF4X3N1cHBvcnRlZF92ZXJzaW9uGAIgASgNUhNtYXhT'
    'dXBwb3J0ZWRWZXJzaW9uElIKFnN1cHBvcnRlZF9jYXBhYmlsaXRpZXMYAyADKA4yGy52YW50cm'
    'EucHJvdG9jb2wuQ2FwYWJpbGl0eVIVc3VwcG9ydGVkQ2FwYWJpbGl0aWVz');

@$core.Deprecated('Use textBodyDescriptor instead')
const TextBody$json = {
  '1': 'TextBody',
  '2': [
    {'1': 'content', '3': 1, '4': 1, '5': 9, '10': 'content'},
  ],
};

/// Descriptor for `TextBody`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List textBodyDescriptor =
    $convert.base64Decode('CghUZXh0Qm9keRIYCgdjb250ZW50GAEgASgJUgdjb250ZW50');

@$core.Deprecated('Use ackBodyDescriptor instead')
const AckBody$json = {
  '1': 'AckBody',
  '2': [
    {
      '1': 'original_message_id',
      '3': 1,
      '4': 1,
      '5': 9,
      '10': 'originalMessageId'
    },
    {
      '1': 'status',
      '3': 2,
      '4': 1,
      '5': 14,
      '6': '.vantra.protocol.DeliveryStatus',
      '10': 'status'
    },
  ],
};

/// Descriptor for `AckBody`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List ackBodyDescriptor = $convert.base64Decode(
    'CgdBY2tCb2R5Ei4KE29yaWdpbmFsX21lc3NhZ2VfaWQYASABKAlSEW9yaWdpbmFsTWVzc2FnZU'
    'lkEjcKBnN0YXR1cxgCIAEoDjIfLnZhbnRyYS5wcm90b2NvbC5EZWxpdmVyeVN0YXR1c1IGc3Rh'
    'dHVz');

@$core.Deprecated('Use protocolErrorPayloadDescriptor instead')
const ProtocolErrorPayload$json = {
  '1': 'ProtocolErrorPayload',
  '2': [
    {'1': 'error_code', '3': 1, '4': 1, '5': 13, '10': 'errorCode'},
    {'1': 'error_message', '3': 2, '4': 1, '5': 9, '10': 'errorMessage'},
    {
      '1': 'related_message_id',
      '3': 3,
      '4': 1,
      '5': 9,
      '10': 'relatedMessageId'
    },
  ],
};

/// Descriptor for `ProtocolErrorPayload`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List protocolErrorPayloadDescriptor = $convert.base64Decode(
    'ChRQcm90b2NvbEVycm9yUGF5bG9hZBIdCgplcnJvcl9jb2RlGAEgASgNUgllcnJvckNvZGUSIw'
    'oNZXJyb3JfbWVzc2FnZRgCIAEoCVIMZXJyb3JNZXNzYWdlEiwKEnJlbGF0ZWRfbWVzc2FnZV9p'
    'ZBgDIAEoCVIQcmVsYXRlZE1lc3NhZ2VJZA==');
