// This is a generated file - do not edit.
//
// Generated from vantra_message.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:core' as $core;

import 'package:fixnum/fixnum.dart' as $fixnum;
import 'package:protobuf/protobuf.dart' as $pb;

import 'vantra_message.pbenum.dart';

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

export 'vantra_message.pbenum.dart';

enum VantraWireEnvelope_Payload {
  handshake,
  encryptedMessage,
  error,
  routedMessage,
  routeRequest,
  routeReply,
  notSet
}

/// Top-level wire message sent across Transport
class VantraWireEnvelope extends $pb.GeneratedMessage {
  factory VantraWireEnvelope({
    $core.int? protocolVersion,
    IdentitySecurePayload? handshake,
    EncryptedEnvelope? encryptedMessage,
    ProtocolErrorPayload? error,
    RouteEnvelope? routedMessage,
    RouteRequest? routeRequest,
    RouteReply? routeReply,
  }) {
    final result = create();
    if (protocolVersion != null) result.protocolVersion = protocolVersion;
    if (handshake != null) result.handshake = handshake;
    if (encryptedMessage != null) result.encryptedMessage = encryptedMessage;
    if (error != null) result.error = error;
    if (routedMessage != null) result.routedMessage = routedMessage;
    if (routeRequest != null) result.routeRequest = routeRequest;
    if (routeReply != null) result.routeReply = routeReply;
    return result;
  }

  VantraWireEnvelope._();

  factory VantraWireEnvelope.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory VantraWireEnvelope.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, VantraWireEnvelope_Payload>
      _VantraWireEnvelope_PayloadByTag = {
    2: VantraWireEnvelope_Payload.handshake,
    3: VantraWireEnvelope_Payload.encryptedMessage,
    4: VantraWireEnvelope_Payload.error,
    5: VantraWireEnvelope_Payload.routedMessage,
    6: VantraWireEnvelope_Payload.routeRequest,
    7: VantraWireEnvelope_Payload.routeReply,
    0: VantraWireEnvelope_Payload.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'VantraWireEnvelope',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'vantra.protocol'),
      createEmptyInstance: create)
    ..oo(0, [2, 3, 4, 5, 6, 7])
    ..aI(1, _omitFieldNames ? '' : 'protocolVersion',
        fieldType: $pb.PbFieldType.OU3)
    ..aOM<IdentitySecurePayload>(2, _omitFieldNames ? '' : 'handshake',
        subBuilder: IdentitySecurePayload.create)
    ..aOM<EncryptedEnvelope>(3, _omitFieldNames ? '' : 'encryptedMessage',
        subBuilder: EncryptedEnvelope.create)
    ..aOM<ProtocolErrorPayload>(4, _omitFieldNames ? '' : 'error',
        subBuilder: ProtocolErrorPayload.create)
    ..aOM<RouteEnvelope>(5, _omitFieldNames ? '' : 'routedMessage',
        subBuilder: RouteEnvelope.create)
    ..aOM<RouteRequest>(6, _omitFieldNames ? '' : 'routeRequest',
        subBuilder: RouteRequest.create)
    ..aOM<RouteReply>(7, _omitFieldNames ? '' : 'routeReply',
        subBuilder: RouteReply.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  VantraWireEnvelope clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  VantraWireEnvelope copyWith(void Function(VantraWireEnvelope) updates) =>
      super.copyWith((message) => updates(message as VantraWireEnvelope))
          as VantraWireEnvelope;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static VantraWireEnvelope create() => VantraWireEnvelope._();
  @$core.override
  VantraWireEnvelope createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static VantraWireEnvelope getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<VantraWireEnvelope>(create);
  static VantraWireEnvelope? _defaultInstance;

  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  @$pb.TagNumber(4)
  @$pb.TagNumber(5)
  @$pb.TagNumber(6)
  @$pb.TagNumber(7)
  VantraWireEnvelope_Payload whichPayload() =>
      _VantraWireEnvelope_PayloadByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  @$pb.TagNumber(4)
  @$pb.TagNumber(5)
  @$pb.TagNumber(6)
  @$pb.TagNumber(7)
  void clearPayload() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  $core.int get protocolVersion => $_getIZ(0);
  @$pb.TagNumber(1)
  set protocolVersion($core.int value) => $_setUnsignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasProtocolVersion() => $_has(0);
  @$pb.TagNumber(1)
  void clearProtocolVersion() => $_clearField(1);

  @$pb.TagNumber(2)
  IdentitySecurePayload get handshake => $_getN(1);
  @$pb.TagNumber(2)
  set handshake(IdentitySecurePayload value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasHandshake() => $_has(1);
  @$pb.TagNumber(2)
  void clearHandshake() => $_clearField(2);
  @$pb.TagNumber(2)
  IdentitySecurePayload ensureHandshake() => $_ensure(1);

  @$pb.TagNumber(3)
  EncryptedEnvelope get encryptedMessage => $_getN(2);
  @$pb.TagNumber(3)
  set encryptedMessage(EncryptedEnvelope value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasEncryptedMessage() => $_has(2);
  @$pb.TagNumber(3)
  void clearEncryptedMessage() => $_clearField(3);
  @$pb.TagNumber(3)
  EncryptedEnvelope ensureEncryptedMessage() => $_ensure(2);

  @$pb.TagNumber(4)
  ProtocolErrorPayload get error => $_getN(3);
  @$pb.TagNumber(4)
  set error(ProtocolErrorPayload value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasError() => $_has(3);
  @$pb.TagNumber(4)
  void clearError() => $_clearField(4);
  @$pb.TagNumber(4)
  ProtocolErrorPayload ensureError() => $_ensure(3);

  @$pb.TagNumber(5)
  RouteEnvelope get routedMessage => $_getN(4);
  @$pb.TagNumber(5)
  set routedMessage(RouteEnvelope value) => $_setField(5, value);
  @$pb.TagNumber(5)
  $core.bool hasRoutedMessage() => $_has(4);
  @$pb.TagNumber(5)
  void clearRoutedMessage() => $_clearField(5);
  @$pb.TagNumber(5)
  RouteEnvelope ensureRoutedMessage() => $_ensure(4);

  @$pb.TagNumber(6)
  RouteRequest get routeRequest => $_getN(5);
  @$pb.TagNumber(6)
  set routeRequest(RouteRequest value) => $_setField(6, value);
  @$pb.TagNumber(6)
  $core.bool hasRouteRequest() => $_has(5);
  @$pb.TagNumber(6)
  void clearRouteRequest() => $_clearField(6);
  @$pb.TagNumber(6)
  RouteRequest ensureRouteRequest() => $_ensure(5);

  @$pb.TagNumber(7)
  RouteReply get routeReply => $_getN(6);
  @$pb.TagNumber(7)
  set routeReply(RouteReply value) => $_setField(7, value);
  @$pb.TagNumber(7)
  $core.bool hasRouteReply() => $_has(6);
  @$pb.TagNumber(7)
  void clearRouteReply() => $_clearField(7);
  @$pb.TagNumber(7)
  RouteReply ensureRouteReply() => $_ensure(6);
}

/// 1. Handshake Payload (Unencrypted wire format during initial connection)
class IdentitySecurePayload extends $pb.GeneratedMessage {
  factory IdentitySecurePayload({
    $core.String? peerId,
    $core.String? displayName,
    $core.List<$core.int>? identityPublicKey,
    $core.List<$core.int>? ephemeralPublicKey,
    $core.List<$core.int>? signature,
    $core.int? minSupportedVersion,
    $core.int? maxSupportedVersion,
    $core.Iterable<Capability>? supportedCapabilities,
  }) {
    final result = create();
    if (peerId != null) result.peerId = peerId;
    if (displayName != null) result.displayName = displayName;
    if (identityPublicKey != null) result.identityPublicKey = identityPublicKey;
    if (ephemeralPublicKey != null)
      result.ephemeralPublicKey = ephemeralPublicKey;
    if (signature != null) result.signature = signature;
    if (minSupportedVersion != null)
      result.minSupportedVersion = minSupportedVersion;
    if (maxSupportedVersion != null)
      result.maxSupportedVersion = maxSupportedVersion;
    if (supportedCapabilities != null)
      result.supportedCapabilities.addAll(supportedCapabilities);
    return result;
  }

  IdentitySecurePayload._();

  factory IdentitySecurePayload.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory IdentitySecurePayload.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'IdentitySecurePayload',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'vantra.protocol'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'peerId')
    ..aOS(2, _omitFieldNames ? '' : 'displayName')
    ..a<$core.List<$core.int>>(
        3, _omitFieldNames ? '' : 'identityPublicKey', $pb.PbFieldType.OY)
    ..a<$core.List<$core.int>>(
        4, _omitFieldNames ? '' : 'ephemeralPublicKey', $pb.PbFieldType.OY)
    ..a<$core.List<$core.int>>(
        5, _omitFieldNames ? '' : 'signature', $pb.PbFieldType.OY)
    ..aI(6, _omitFieldNames ? '' : 'minSupportedVersion',
        fieldType: $pb.PbFieldType.OU3)
    ..aI(7, _omitFieldNames ? '' : 'maxSupportedVersion',
        fieldType: $pb.PbFieldType.OU3)
    ..pc<Capability>(
        8, _omitFieldNames ? '' : 'supportedCapabilities', $pb.PbFieldType.KE,
        valueOf: Capability.valueOf,
        enumValues: Capability.values,
        defaultEnumValue: Capability.CAPABILITY_UNSPECIFIED)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  IdentitySecurePayload clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  IdentitySecurePayload copyWith(
          void Function(IdentitySecurePayload) updates) =>
      super.copyWith((message) => updates(message as IdentitySecurePayload))
          as IdentitySecurePayload;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static IdentitySecurePayload create() => IdentitySecurePayload._();
  @$core.override
  IdentitySecurePayload createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static IdentitySecurePayload getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<IdentitySecurePayload>(create);
  static IdentitySecurePayload? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get peerId => $_getSZ(0);
  @$pb.TagNumber(1)
  set peerId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasPeerId() => $_has(0);
  @$pb.TagNumber(1)
  void clearPeerId() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get displayName => $_getSZ(1);
  @$pb.TagNumber(2)
  set displayName($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasDisplayName() => $_has(1);
  @$pb.TagNumber(2)
  void clearDisplayName() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.List<$core.int> get identityPublicKey => $_getN(2);
  @$pb.TagNumber(3)
  set identityPublicKey($core.List<$core.int> value) => $_setBytes(2, value);
  @$pb.TagNumber(3)
  $core.bool hasIdentityPublicKey() => $_has(2);
  @$pb.TagNumber(3)
  void clearIdentityPublicKey() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.List<$core.int> get ephemeralPublicKey => $_getN(3);
  @$pb.TagNumber(4)
  set ephemeralPublicKey($core.List<$core.int> value) => $_setBytes(3, value);
  @$pb.TagNumber(4)
  $core.bool hasEphemeralPublicKey() => $_has(3);
  @$pb.TagNumber(4)
  void clearEphemeralPublicKey() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.List<$core.int> get signature => $_getN(4);
  @$pb.TagNumber(5)
  set signature($core.List<$core.int> value) => $_setBytes(4, value);
  @$pb.TagNumber(5)
  $core.bool hasSignature() => $_has(4);
  @$pb.TagNumber(5)
  void clearSignature() => $_clearField(5);

  /// New in V2:
  @$pb.TagNumber(6)
  $core.int get minSupportedVersion => $_getIZ(5);
  @$pb.TagNumber(6)
  set minSupportedVersion($core.int value) => $_setUnsignedInt32(5, value);
  @$pb.TagNumber(6)
  $core.bool hasMinSupportedVersion() => $_has(5);
  @$pb.TagNumber(6)
  void clearMinSupportedVersion() => $_clearField(6);

  @$pb.TagNumber(7)
  $core.int get maxSupportedVersion => $_getIZ(6);
  @$pb.TagNumber(7)
  set maxSupportedVersion($core.int value) => $_setUnsignedInt32(6, value);
  @$pb.TagNumber(7)
  $core.bool hasMaxSupportedVersion() => $_has(6);
  @$pb.TagNumber(7)
  void clearMaxSupportedVersion() => $_clearField(7);

  @$pb.TagNumber(8)
  $pb.PbList<Capability> get supportedCapabilities => $_getList(7);
}

/// 2. Encrypted Envelope (Wire container for encrypted payloads)
class EncryptedEnvelope extends $pb.GeneratedMessage {
  factory EncryptedEnvelope({
    $core.String? messageId,
    $core.String? sessionId,
    $fixnum.Int64? sequence,
    $core.List<$core.int>? nonce,
    $core.List<$core.int>? ciphertext,
    $core.List<$core.int>? mac,
  }) {
    final result = create();
    if (messageId != null) result.messageId = messageId;
    if (sessionId != null) result.sessionId = sessionId;
    if (sequence != null) result.sequence = sequence;
    if (nonce != null) result.nonce = nonce;
    if (ciphertext != null) result.ciphertext = ciphertext;
    if (mac != null) result.mac = mac;
    return result;
  }

  EncryptedEnvelope._();

  factory EncryptedEnvelope.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory EncryptedEnvelope.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'EncryptedEnvelope',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'vantra.protocol'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'messageId')
    ..aOS(2, _omitFieldNames ? '' : 'sessionId')
    ..a<$fixnum.Int64>(
        3, _omitFieldNames ? '' : 'sequence', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$core.List<$core.int>>(
        4, _omitFieldNames ? '' : 'nonce', $pb.PbFieldType.OY)
    ..a<$core.List<$core.int>>(
        5, _omitFieldNames ? '' : 'ciphertext', $pb.PbFieldType.OY)
    ..a<$core.List<$core.int>>(
        6, _omitFieldNames ? '' : 'mac', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  EncryptedEnvelope clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  EncryptedEnvelope copyWith(void Function(EncryptedEnvelope) updates) =>
      super.copyWith((message) => updates(message as EncryptedEnvelope))
          as EncryptedEnvelope;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static EncryptedEnvelope create() => EncryptedEnvelope._();
  @$core.override
  EncryptedEnvelope createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static EncryptedEnvelope getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<EncryptedEnvelope>(create);
  static EncryptedEnvelope? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get messageId => $_getSZ(0);
  @$pb.TagNumber(1)
  set messageId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasMessageId() => $_has(0);
  @$pb.TagNumber(1)
  void clearMessageId() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get sessionId => $_getSZ(1);
  @$pb.TagNumber(2)
  set sessionId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasSessionId() => $_has(1);
  @$pb.TagNumber(2)
  void clearSessionId() => $_clearField(2);

  @$pb.TagNumber(3)
  $fixnum.Int64 get sequence => $_getI64(2);
  @$pb.TagNumber(3)
  set sequence($fixnum.Int64 value) => $_setInt64(2, value);
  @$pb.TagNumber(3)
  $core.bool hasSequence() => $_has(2);
  @$pb.TagNumber(3)
  void clearSequence() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.List<$core.int> get nonce => $_getN(3);
  @$pb.TagNumber(4)
  set nonce($core.List<$core.int> value) => $_setBytes(3, value);
  @$pb.TagNumber(4)
  $core.bool hasNonce() => $_has(3);
  @$pb.TagNumber(4)
  void clearNonce() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.List<$core.int> get ciphertext => $_getN(4);
  @$pb.TagNumber(5)
  set ciphertext($core.List<$core.int> value) => $_setBytes(4, value);
  @$pb.TagNumber(5)
  $core.bool hasCiphertext() => $_has(4);
  @$pb.TagNumber(5)
  void clearCiphertext() => $_clearField(5);

  @$pb.TagNumber(6)
  $core.List<$core.int> get mac => $_getN(5);
  @$pb.TagNumber(6)
  set mac($core.List<$core.int> value) => $_setBytes(5, value);
  @$pb.TagNumber(6)
  $core.bool hasMac() => $_has(5);
  @$pb.TagNumber(6)
  void clearMac() => $_clearField(6);
}

enum VantraPlaintext_Body {
  text,
  ack,
  capabilitiesExchange,
  mediaControl,
  mediaChunk,
  notSet
}

/// 3. Plaintext Payload (Encrypted inside EncryptedEnvelope.ciphertext)
class VantraPlaintext extends $pb.GeneratedMessage {
  factory VantraPlaintext({
    $core.String? messageId,
    $core.String? sessionId,
    $fixnum.Int64? sequence,
    $fixnum.Int64? timestampMs,
    $core.String? senderId,
    $core.String? receiverId,
    TextBody? text,
    AckBody? ack,
    CapabilitiesExchange? capabilitiesExchange,
    MediaControl? mediaControl,
    MediaChunk? mediaChunk,
  }) {
    final result = create();
    if (messageId != null) result.messageId = messageId;
    if (sessionId != null) result.sessionId = sessionId;
    if (sequence != null) result.sequence = sequence;
    if (timestampMs != null) result.timestampMs = timestampMs;
    if (senderId != null) result.senderId = senderId;
    if (receiverId != null) result.receiverId = receiverId;
    if (text != null) result.text = text;
    if (ack != null) result.ack = ack;
    if (capabilitiesExchange != null)
      result.capabilitiesExchange = capabilitiesExchange;
    if (mediaControl != null) result.mediaControl = mediaControl;
    if (mediaChunk != null) result.mediaChunk = mediaChunk;
    return result;
  }

  VantraPlaintext._();

  factory VantraPlaintext.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory VantraPlaintext.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, VantraPlaintext_Body>
      _VantraPlaintext_BodyByTag = {
    7: VantraPlaintext_Body.text,
    8: VantraPlaintext_Body.ack,
    9: VantraPlaintext_Body.capabilitiesExchange,
    10: VantraPlaintext_Body.mediaControl,
    11: VantraPlaintext_Body.mediaChunk,
    0: VantraPlaintext_Body.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'VantraPlaintext',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'vantra.protocol'),
      createEmptyInstance: create)
    ..oo(0, [7, 8, 9, 10, 11])
    ..aOS(1, _omitFieldNames ? '' : 'messageId')
    ..aOS(2, _omitFieldNames ? '' : 'sessionId')
    ..a<$fixnum.Int64>(
        3, _omitFieldNames ? '' : 'sequence', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..aInt64(4, _omitFieldNames ? '' : 'timestampMs')
    ..aOS(5, _omitFieldNames ? '' : 'senderId')
    ..aOS(6, _omitFieldNames ? '' : 'receiverId')
    ..aOM<TextBody>(7, _omitFieldNames ? '' : 'text',
        subBuilder: TextBody.create)
    ..aOM<AckBody>(8, _omitFieldNames ? '' : 'ack', subBuilder: AckBody.create)
    ..aOM<CapabilitiesExchange>(
        9, _omitFieldNames ? '' : 'capabilitiesExchange',
        subBuilder: CapabilitiesExchange.create)
    ..aOM<MediaControl>(10, _omitFieldNames ? '' : 'mediaControl',
        subBuilder: MediaControl.create)
    ..aOM<MediaChunk>(11, _omitFieldNames ? '' : 'mediaChunk',
        subBuilder: MediaChunk.create)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  VantraPlaintext clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  VantraPlaintext copyWith(void Function(VantraPlaintext) updates) =>
      super.copyWith((message) => updates(message as VantraPlaintext))
          as VantraPlaintext;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static VantraPlaintext create() => VantraPlaintext._();
  @$core.override
  VantraPlaintext createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static VantraPlaintext getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<VantraPlaintext>(create);
  static VantraPlaintext? _defaultInstance;

  @$pb.TagNumber(7)
  @$pb.TagNumber(8)
  @$pb.TagNumber(9)
  @$pb.TagNumber(10)
  @$pb.TagNumber(11)
  VantraPlaintext_Body whichBody() =>
      _VantraPlaintext_BodyByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(7)
  @$pb.TagNumber(8)
  @$pb.TagNumber(9)
  @$pb.TagNumber(10)
  @$pb.TagNumber(11)
  void clearBody() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  $core.String get messageId => $_getSZ(0);
  @$pb.TagNumber(1)
  set messageId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasMessageId() => $_has(0);
  @$pb.TagNumber(1)
  void clearMessageId() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get sessionId => $_getSZ(1);
  @$pb.TagNumber(2)
  set sessionId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasSessionId() => $_has(1);
  @$pb.TagNumber(2)
  void clearSessionId() => $_clearField(2);

  @$pb.TagNumber(3)
  $fixnum.Int64 get sequence => $_getI64(2);
  @$pb.TagNumber(3)
  set sequence($fixnum.Int64 value) => $_setInt64(2, value);
  @$pb.TagNumber(3)
  $core.bool hasSequence() => $_has(2);
  @$pb.TagNumber(3)
  void clearSequence() => $_clearField(3);

  @$pb.TagNumber(4)
  $fixnum.Int64 get timestampMs => $_getI64(3);
  @$pb.TagNumber(4)
  set timestampMs($fixnum.Int64 value) => $_setInt64(3, value);
  @$pb.TagNumber(4)
  $core.bool hasTimestampMs() => $_has(3);
  @$pb.TagNumber(4)
  void clearTimestampMs() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.String get senderId => $_getSZ(4);
  @$pb.TagNumber(5)
  set senderId($core.String value) => $_setString(4, value);
  @$pb.TagNumber(5)
  $core.bool hasSenderId() => $_has(4);
  @$pb.TagNumber(5)
  void clearSenderId() => $_clearField(5);

  @$pb.TagNumber(6)
  $core.String get receiverId => $_getSZ(5);
  @$pb.TagNumber(6)
  set receiverId($core.String value) => $_setString(5, value);
  @$pb.TagNumber(6)
  $core.bool hasReceiverId() => $_has(5);
  @$pb.TagNumber(6)
  void clearReceiverId() => $_clearField(6);

  @$pb.TagNumber(7)
  TextBody get text => $_getN(6);
  @$pb.TagNumber(7)
  set text(TextBody value) => $_setField(7, value);
  @$pb.TagNumber(7)
  $core.bool hasText() => $_has(6);
  @$pb.TagNumber(7)
  void clearText() => $_clearField(7);
  @$pb.TagNumber(7)
  TextBody ensureText() => $_ensure(6);

  @$pb.TagNumber(8)
  AckBody get ack => $_getN(7);
  @$pb.TagNumber(8)
  set ack(AckBody value) => $_setField(8, value);
  @$pb.TagNumber(8)
  $core.bool hasAck() => $_has(7);
  @$pb.TagNumber(8)
  void clearAck() => $_clearField(8);
  @$pb.TagNumber(8)
  AckBody ensureAck() => $_ensure(7);

  @$pb.TagNumber(9)
  CapabilitiesExchange get capabilitiesExchange => $_getN(8);
  @$pb.TagNumber(9)
  set capabilitiesExchange(CapabilitiesExchange value) => $_setField(9, value);
  @$pb.TagNumber(9)
  $core.bool hasCapabilitiesExchange() => $_has(8);
  @$pb.TagNumber(9)
  void clearCapabilitiesExchange() => $_clearField(9);
  @$pb.TagNumber(9)
  CapabilitiesExchange ensureCapabilitiesExchange() => $_ensure(8);

  @$pb.TagNumber(10)
  MediaControl get mediaControl => $_getN(9);
  @$pb.TagNumber(10)
  set mediaControl(MediaControl value) => $_setField(10, value);
  @$pb.TagNumber(10)
  $core.bool hasMediaControl() => $_has(9);
  @$pb.TagNumber(10)
  void clearMediaControl() => $_clearField(10);
  @$pb.TagNumber(10)
  MediaControl ensureMediaControl() => $_ensure(9);

  @$pb.TagNumber(11)
  MediaChunk get mediaChunk => $_getN(10);
  @$pb.TagNumber(11)
  set mediaChunk(MediaChunk value) => $_setField(11, value);
  @$pb.TagNumber(11)
  $core.bool hasMediaChunk() => $_has(10);
  @$pb.TagNumber(11)
  void clearMediaChunk() => $_clearField(11);
  @$pb.TagNumber(11)
  MediaChunk ensureMediaChunk() => $_ensure(10);
}

class MediaControl extends $pb.GeneratedMessage {
  factory MediaControl({
    MediaControl_Type? type,
    $core.String? transferId,
    $core.String? fileName,
    $fixnum.Int64? fileSize,
    $core.String? mimeType,
    $core.int? totalChunks,
    $core.int? chunkSize,
    $core.int? width,
    $core.int? height,
    $core.String? caption,
    $core.int? nextExpectedChunk,
    $core.String? sha256,
  }) {
    final result = create();
    if (type != null) result.type = type;
    if (transferId != null) result.transferId = transferId;
    if (fileName != null) result.fileName = fileName;
    if (fileSize != null) result.fileSize = fileSize;
    if (mimeType != null) result.mimeType = mimeType;
    if (totalChunks != null) result.totalChunks = totalChunks;
    if (chunkSize != null) result.chunkSize = chunkSize;
    if (width != null) result.width = width;
    if (height != null) result.height = height;
    if (caption != null) result.caption = caption;
    if (nextExpectedChunk != null) result.nextExpectedChunk = nextExpectedChunk;
    if (sha256 != null) result.sha256 = sha256;
    return result;
  }

  MediaControl._();

  factory MediaControl.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory MediaControl.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'MediaControl',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'vantra.protocol'),
      createEmptyInstance: create)
    ..aE<MediaControl_Type>(1, _omitFieldNames ? '' : 'type',
        enumValues: MediaControl_Type.values)
    ..aOS(2, _omitFieldNames ? '' : 'transferId')
    ..aOS(3, _omitFieldNames ? '' : 'fileName')
    ..a<$fixnum.Int64>(
        4, _omitFieldNames ? '' : 'fileSize', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..aOS(5, _omitFieldNames ? '' : 'mimeType')
    ..aI(6, _omitFieldNames ? '' : 'totalChunks',
        fieldType: $pb.PbFieldType.OU3)
    ..aI(7, _omitFieldNames ? '' : 'chunkSize', fieldType: $pb.PbFieldType.OU3)
    ..aI(8, _omitFieldNames ? '' : 'width', fieldType: $pb.PbFieldType.OU3)
    ..aI(9, _omitFieldNames ? '' : 'height', fieldType: $pb.PbFieldType.OU3)
    ..aOS(10, _omitFieldNames ? '' : 'caption')
    ..aI(11, _omitFieldNames ? '' : 'nextExpectedChunk',
        fieldType: $pb.PbFieldType.OU3)
    ..aOS(12, _omitFieldNames ? '' : 'sha256')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MediaControl clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MediaControl copyWith(void Function(MediaControl) updates) =>
      super.copyWith((message) => updates(message as MediaControl))
          as MediaControl;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static MediaControl create() => MediaControl._();
  @$core.override
  MediaControl createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static MediaControl getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<MediaControl>(create);
  static MediaControl? _defaultInstance;

  @$pb.TagNumber(1)
  MediaControl_Type get type => $_getN(0);
  @$pb.TagNumber(1)
  set type(MediaControl_Type value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasType() => $_has(0);
  @$pb.TagNumber(1)
  void clearType() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get transferId => $_getSZ(1);
  @$pb.TagNumber(2)
  set transferId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasTransferId() => $_has(1);
  @$pb.TagNumber(2)
  void clearTransferId() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get fileName => $_getSZ(2);
  @$pb.TagNumber(3)
  set fileName($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasFileName() => $_has(2);
  @$pb.TagNumber(3)
  void clearFileName() => $_clearField(3);

  @$pb.TagNumber(4)
  $fixnum.Int64 get fileSize => $_getI64(3);
  @$pb.TagNumber(4)
  set fileSize($fixnum.Int64 value) => $_setInt64(3, value);
  @$pb.TagNumber(4)
  $core.bool hasFileSize() => $_has(3);
  @$pb.TagNumber(4)
  void clearFileSize() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.String get mimeType => $_getSZ(4);
  @$pb.TagNumber(5)
  set mimeType($core.String value) => $_setString(4, value);
  @$pb.TagNumber(5)
  $core.bool hasMimeType() => $_has(4);
  @$pb.TagNumber(5)
  void clearMimeType() => $_clearField(5);

  @$pb.TagNumber(6)
  $core.int get totalChunks => $_getIZ(5);
  @$pb.TagNumber(6)
  set totalChunks($core.int value) => $_setUnsignedInt32(5, value);
  @$pb.TagNumber(6)
  $core.bool hasTotalChunks() => $_has(5);
  @$pb.TagNumber(6)
  void clearTotalChunks() => $_clearField(6);

  @$pb.TagNumber(7)
  $core.int get chunkSize => $_getIZ(6);
  @$pb.TagNumber(7)
  set chunkSize($core.int value) => $_setUnsignedInt32(6, value);
  @$pb.TagNumber(7)
  $core.bool hasChunkSize() => $_has(6);
  @$pb.TagNumber(7)
  void clearChunkSize() => $_clearField(7);

  @$pb.TagNumber(8)
  $core.int get width => $_getIZ(7);
  @$pb.TagNumber(8)
  set width($core.int value) => $_setUnsignedInt32(7, value);
  @$pb.TagNumber(8)
  $core.bool hasWidth() => $_has(7);
  @$pb.TagNumber(8)
  void clearWidth() => $_clearField(8);

  @$pb.TagNumber(9)
  $core.int get height => $_getIZ(8);
  @$pb.TagNumber(9)
  set height($core.int value) => $_setUnsignedInt32(8, value);
  @$pb.TagNumber(9)
  $core.bool hasHeight() => $_has(8);
  @$pb.TagNumber(9)
  void clearHeight() => $_clearField(9);

  @$pb.TagNumber(10)
  $core.String get caption => $_getSZ(9);
  @$pb.TagNumber(10)
  set caption($core.String value) => $_setString(9, value);
  @$pb.TagNumber(10)
  $core.bool hasCaption() => $_has(9);
  @$pb.TagNumber(10)
  void clearCaption() => $_clearField(10);

  @$pb.TagNumber(11)
  $core.int get nextExpectedChunk => $_getIZ(10);
  @$pb.TagNumber(11)
  set nextExpectedChunk($core.int value) => $_setUnsignedInt32(10, value);
  @$pb.TagNumber(11)
  $core.bool hasNextExpectedChunk() => $_has(10);
  @$pb.TagNumber(11)
  void clearNextExpectedChunk() => $_clearField(11);

  @$pb.TagNumber(12)
  $core.String get sha256 => $_getSZ(11);
  @$pb.TagNumber(12)
  set sha256($core.String value) => $_setString(11, value);
  @$pb.TagNumber(12)
  $core.bool hasSha256() => $_has(11);
  @$pb.TagNumber(12)
  void clearSha256() => $_clearField(12);
}

class MediaChunk extends $pb.GeneratedMessage {
  factory MediaChunk({
    $core.String? transferId,
    $core.int? chunkIndex,
    $core.int? totalChunks,
    $core.List<$core.int>? data,
  }) {
    final result = create();
    if (transferId != null) result.transferId = transferId;
    if (chunkIndex != null) result.chunkIndex = chunkIndex;
    if (totalChunks != null) result.totalChunks = totalChunks;
    if (data != null) result.data = data;
    return result;
  }

  MediaChunk._();

  factory MediaChunk.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory MediaChunk.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'MediaChunk',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'vantra.protocol'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'transferId')
    ..aI(2, _omitFieldNames ? '' : 'chunkIndex', fieldType: $pb.PbFieldType.OU3)
    ..aI(3, _omitFieldNames ? '' : 'totalChunks',
        fieldType: $pb.PbFieldType.OU3)
    ..a<$core.List<$core.int>>(
        4, _omitFieldNames ? '' : 'data', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MediaChunk clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MediaChunk copyWith(void Function(MediaChunk) updates) =>
      super.copyWith((message) => updates(message as MediaChunk)) as MediaChunk;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static MediaChunk create() => MediaChunk._();
  @$core.override
  MediaChunk createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static MediaChunk getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<MediaChunk>(create);
  static MediaChunk? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get transferId => $_getSZ(0);
  @$pb.TagNumber(1)
  set transferId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasTransferId() => $_has(0);
  @$pb.TagNumber(1)
  void clearTransferId() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.int get chunkIndex => $_getIZ(1);
  @$pb.TagNumber(2)
  set chunkIndex($core.int value) => $_setUnsignedInt32(1, value);
  @$pb.TagNumber(2)
  $core.bool hasChunkIndex() => $_has(1);
  @$pb.TagNumber(2)
  void clearChunkIndex() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.int get totalChunks => $_getIZ(2);
  @$pb.TagNumber(3)
  set totalChunks($core.int value) => $_setUnsignedInt32(2, value);
  @$pb.TagNumber(3)
  $core.bool hasTotalChunks() => $_has(2);
  @$pb.TagNumber(3)
  void clearTotalChunks() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.List<$core.int> get data => $_getN(3);
  @$pb.TagNumber(4)
  set data($core.List<$core.int> value) => $_setBytes(3, value);
  @$pb.TagNumber(4)
  $core.bool hasData() => $_has(3);
  @$pb.TagNumber(4)
  void clearData() => $_clearField(4);
}

class CapabilitiesExchange extends $pb.GeneratedMessage {
  factory CapabilitiesExchange({
    $core.int? minSupportedVersion,
    $core.int? maxSupportedVersion,
    $core.Iterable<Capability>? supportedCapabilities,
  }) {
    final result = create();
    if (minSupportedVersion != null)
      result.minSupportedVersion = minSupportedVersion;
    if (maxSupportedVersion != null)
      result.maxSupportedVersion = maxSupportedVersion;
    if (supportedCapabilities != null)
      result.supportedCapabilities.addAll(supportedCapabilities);
    return result;
  }

  CapabilitiesExchange._();

  factory CapabilitiesExchange.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory CapabilitiesExchange.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CapabilitiesExchange',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'vantra.protocol'),
      createEmptyInstance: create)
    ..aI(1, _omitFieldNames ? '' : 'minSupportedVersion',
        fieldType: $pb.PbFieldType.OU3)
    ..aI(2, _omitFieldNames ? '' : 'maxSupportedVersion',
        fieldType: $pb.PbFieldType.OU3)
    ..pc<Capability>(
        3, _omitFieldNames ? '' : 'supportedCapabilities', $pb.PbFieldType.KE,
        valueOf: Capability.valueOf,
        enumValues: Capability.values,
        defaultEnumValue: Capability.CAPABILITY_UNSPECIFIED)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CapabilitiesExchange clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CapabilitiesExchange copyWith(void Function(CapabilitiesExchange) updates) =>
      super.copyWith((message) => updates(message as CapabilitiesExchange))
          as CapabilitiesExchange;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static CapabilitiesExchange create() => CapabilitiesExchange._();
  @$core.override
  CapabilitiesExchange createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static CapabilitiesExchange getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<CapabilitiesExchange>(create);
  static CapabilitiesExchange? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get minSupportedVersion => $_getIZ(0);
  @$pb.TagNumber(1)
  set minSupportedVersion($core.int value) => $_setUnsignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasMinSupportedVersion() => $_has(0);
  @$pb.TagNumber(1)
  void clearMinSupportedVersion() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.int get maxSupportedVersion => $_getIZ(1);
  @$pb.TagNumber(2)
  set maxSupportedVersion($core.int value) => $_setUnsignedInt32(1, value);
  @$pb.TagNumber(2)
  $core.bool hasMaxSupportedVersion() => $_has(1);
  @$pb.TagNumber(2)
  void clearMaxSupportedVersion() => $_clearField(2);

  @$pb.TagNumber(3)
  $pb.PbList<Capability> get supportedCapabilities => $_getList(2);
}

class TextBody extends $pb.GeneratedMessage {
  factory TextBody({
    $core.String? content,
  }) {
    final result = create();
    if (content != null) result.content = content;
    return result;
  }

  TextBody._();

  factory TextBody.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory TextBody.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'TextBody',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'vantra.protocol'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'content')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TextBody clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TextBody copyWith(void Function(TextBody) updates) =>
      super.copyWith((message) => updates(message as TextBody)) as TextBody;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static TextBody create() => TextBody._();
  @$core.override
  TextBody createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static TextBody getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<TextBody>(create);
  static TextBody? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get content => $_getSZ(0);
  @$pb.TagNumber(1)
  set content($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasContent() => $_has(0);
  @$pb.TagNumber(1)
  void clearContent() => $_clearField(1);
}

class AckBody extends $pb.GeneratedMessage {
  factory AckBody({
    $core.String? originalMessageId,
    DeliveryStatus? status,
  }) {
    final result = create();
    if (originalMessageId != null) result.originalMessageId = originalMessageId;
    if (status != null) result.status = status;
    return result;
  }

  AckBody._();

  factory AckBody.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory AckBody.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'AckBody',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'vantra.protocol'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'originalMessageId')
    ..aE<DeliveryStatus>(2, _omitFieldNames ? '' : 'status',
        enumValues: DeliveryStatus.values)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AckBody clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AckBody copyWith(void Function(AckBody) updates) =>
      super.copyWith((message) => updates(message as AckBody)) as AckBody;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static AckBody create() => AckBody._();
  @$core.override
  AckBody createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static AckBody getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<AckBody>(create);
  static AckBody? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get originalMessageId => $_getSZ(0);
  @$pb.TagNumber(1)
  set originalMessageId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasOriginalMessageId() => $_has(0);
  @$pb.TagNumber(1)
  void clearOriginalMessageId() => $_clearField(1);

  @$pb.TagNumber(2)
  DeliveryStatus get status => $_getN(1);
  @$pb.TagNumber(2)
  set status(DeliveryStatus value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasStatus() => $_has(1);
  @$pb.TagNumber(2)
  void clearStatus() => $_clearField(2);
}

/// 4. Pre-session Protocol Error (Outer wire payload for unauthenticated version/malformed errors)
class ProtocolErrorPayload extends $pb.GeneratedMessage {
  factory ProtocolErrorPayload({
    $core.int? errorCode,
    $core.String? errorMessage,
    $core.String? relatedMessageId,
  }) {
    final result = create();
    if (errorCode != null) result.errorCode = errorCode;
    if (errorMessage != null) result.errorMessage = errorMessage;
    if (relatedMessageId != null) result.relatedMessageId = relatedMessageId;
    return result;
  }

  ProtocolErrorPayload._();

  factory ProtocolErrorPayload.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory ProtocolErrorPayload.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ProtocolErrorPayload',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'vantra.protocol'),
      createEmptyInstance: create)
    ..aI(1, _omitFieldNames ? '' : 'errorCode', fieldType: $pb.PbFieldType.OU3)
    ..aOS(2, _omitFieldNames ? '' : 'errorMessage')
    ..aOS(3, _omitFieldNames ? '' : 'relatedMessageId')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ProtocolErrorPayload clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ProtocolErrorPayload copyWith(void Function(ProtocolErrorPayload) updates) =>
      super.copyWith((message) => updates(message as ProtocolErrorPayload))
          as ProtocolErrorPayload;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static ProtocolErrorPayload create() => ProtocolErrorPayload._();
  @$core.override
  ProtocolErrorPayload createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static ProtocolErrorPayload getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ProtocolErrorPayload>(create);
  static ProtocolErrorPayload? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get errorCode => $_getIZ(0);
  @$pb.TagNumber(1)
  set errorCode($core.int value) => $_setUnsignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasErrorCode() => $_has(0);
  @$pb.TagNumber(1)
  void clearErrorCode() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get errorMessage => $_getSZ(1);
  @$pb.TagNumber(2)
  set errorMessage($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasErrorMessage() => $_has(1);
  @$pb.TagNumber(2)
  void clearErrorMessage() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get relatedMessageId => $_getSZ(2);
  @$pb.TagNumber(3)
  set relatedMessageId($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasRelatedMessageId() => $_has(2);
  @$pb.TagNumber(3)
  void clearRelatedMessageId() => $_clearField(3);
}

/// 5. Routing Envelope & Mesh Control Messages (Phase 16)
class RouteEnvelope extends $pb.GeneratedMessage {
  factory RouteEnvelope({
    $core.String? packetId,
    $core.String? sourcePeerId,
    $core.String? destinationPeerId,
    $core.int? hopCount,
    $core.int? maxHops,
    $core.List<$core.int>? encryptedPayload,
  }) {
    final result = create();
    if (packetId != null) result.packetId = packetId;
    if (sourcePeerId != null) result.sourcePeerId = sourcePeerId;
    if (destinationPeerId != null) result.destinationPeerId = destinationPeerId;
    if (hopCount != null) result.hopCount = hopCount;
    if (maxHops != null) result.maxHops = maxHops;
    if (encryptedPayload != null) result.encryptedPayload = encryptedPayload;
    return result;
  }

  RouteEnvelope._();

  factory RouteEnvelope.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory RouteEnvelope.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RouteEnvelope',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'vantra.protocol'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'packetId')
    ..aOS(2, _omitFieldNames ? '' : 'sourcePeerId')
    ..aOS(3, _omitFieldNames ? '' : 'destinationPeerId')
    ..aI(4, _omitFieldNames ? '' : 'hopCount', fieldType: $pb.PbFieldType.OU3)
    ..aI(5, _omitFieldNames ? '' : 'maxHops', fieldType: $pb.PbFieldType.OU3)
    ..a<$core.List<$core.int>>(
        6, _omitFieldNames ? '' : 'encryptedPayload', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RouteEnvelope clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RouteEnvelope copyWith(void Function(RouteEnvelope) updates) =>
      super.copyWith((message) => updates(message as RouteEnvelope))
          as RouteEnvelope;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static RouteEnvelope create() => RouteEnvelope._();
  @$core.override
  RouteEnvelope createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static RouteEnvelope getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<RouteEnvelope>(create);
  static RouteEnvelope? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get packetId => $_getSZ(0);
  @$pb.TagNumber(1)
  set packetId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasPacketId() => $_has(0);
  @$pb.TagNumber(1)
  void clearPacketId() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get sourcePeerId => $_getSZ(1);
  @$pb.TagNumber(2)
  set sourcePeerId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasSourcePeerId() => $_has(1);
  @$pb.TagNumber(2)
  void clearSourcePeerId() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get destinationPeerId => $_getSZ(2);
  @$pb.TagNumber(3)
  set destinationPeerId($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasDestinationPeerId() => $_has(2);
  @$pb.TagNumber(3)
  void clearDestinationPeerId() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.int get hopCount => $_getIZ(3);
  @$pb.TagNumber(4)
  set hopCount($core.int value) => $_setUnsignedInt32(3, value);
  @$pb.TagNumber(4)
  $core.bool hasHopCount() => $_has(3);
  @$pb.TagNumber(4)
  void clearHopCount() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.int get maxHops => $_getIZ(4);
  @$pb.TagNumber(5)
  set maxHops($core.int value) => $_setUnsignedInt32(4, value);
  @$pb.TagNumber(5)
  $core.bool hasMaxHops() => $_has(4);
  @$pb.TagNumber(5)
  void clearMaxHops() => $_clearField(5);

  @$pb.TagNumber(6)
  $core.List<$core.int> get encryptedPayload => $_getN(5);
  @$pb.TagNumber(6)
  set encryptedPayload($core.List<$core.int> value) => $_setBytes(5, value);
  @$pb.TagNumber(6)
  $core.bool hasEncryptedPayload() => $_has(5);
  @$pb.TagNumber(6)
  void clearEncryptedPayload() => $_clearField(6);
}

class RouteRequest extends $pb.GeneratedMessage {
  factory RouteRequest({
    $core.String? requestId,
    $core.String? sourcePeerId,
    $core.String? destinationPeerId,
    $core.int? hopCount,
    $core.int? maxHops,
  }) {
    final result = create();
    if (requestId != null) result.requestId = requestId;
    if (sourcePeerId != null) result.sourcePeerId = sourcePeerId;
    if (destinationPeerId != null) result.destinationPeerId = destinationPeerId;
    if (hopCount != null) result.hopCount = hopCount;
    if (maxHops != null) result.maxHops = maxHops;
    return result;
  }

  RouteRequest._();

  factory RouteRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory RouteRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RouteRequest',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'vantra.protocol'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'requestId')
    ..aOS(2, _omitFieldNames ? '' : 'sourcePeerId')
    ..aOS(3, _omitFieldNames ? '' : 'destinationPeerId')
    ..aI(4, _omitFieldNames ? '' : 'hopCount', fieldType: $pb.PbFieldType.OU3)
    ..aI(5, _omitFieldNames ? '' : 'maxHops', fieldType: $pb.PbFieldType.OU3)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RouteRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RouteRequest copyWith(void Function(RouteRequest) updates) =>
      super.copyWith((message) => updates(message as RouteRequest))
          as RouteRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static RouteRequest create() => RouteRequest._();
  @$core.override
  RouteRequest createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static RouteRequest getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<RouteRequest>(create);
  static RouteRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get requestId => $_getSZ(0);
  @$pb.TagNumber(1)
  set requestId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasRequestId() => $_has(0);
  @$pb.TagNumber(1)
  void clearRequestId() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get sourcePeerId => $_getSZ(1);
  @$pb.TagNumber(2)
  set sourcePeerId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasSourcePeerId() => $_has(1);
  @$pb.TagNumber(2)
  void clearSourcePeerId() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get destinationPeerId => $_getSZ(2);
  @$pb.TagNumber(3)
  set destinationPeerId($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasDestinationPeerId() => $_has(2);
  @$pb.TagNumber(3)
  void clearDestinationPeerId() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.int get hopCount => $_getIZ(3);
  @$pb.TagNumber(4)
  set hopCount($core.int value) => $_setUnsignedInt32(3, value);
  @$pb.TagNumber(4)
  $core.bool hasHopCount() => $_has(3);
  @$pb.TagNumber(4)
  void clearHopCount() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.int get maxHops => $_getIZ(4);
  @$pb.TagNumber(5)
  set maxHops($core.int value) => $_setUnsignedInt32(4, value);
  @$pb.TagNumber(5)
  $core.bool hasMaxHops() => $_has(4);
  @$pb.TagNumber(5)
  void clearMaxHops() => $_clearField(5);
}

class RouteReply extends $pb.GeneratedMessage {
  factory RouteReply({
    $core.String? requestId,
    $core.String? sourcePeerId,
    $core.String? destinationPeerId,
    $core.int? hopCount,
    $core.int? maxHops,
    $core.List<$core.int>? signature,
  }) {
    final result = create();
    if (requestId != null) result.requestId = requestId;
    if (sourcePeerId != null) result.sourcePeerId = sourcePeerId;
    if (destinationPeerId != null) result.destinationPeerId = destinationPeerId;
    if (hopCount != null) result.hopCount = hopCount;
    if (maxHops != null) result.maxHops = maxHops;
    if (signature != null) result.signature = signature;
    return result;
  }

  RouteReply._();

  factory RouteReply.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(data, registry);
  factory RouteReply.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RouteReply',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'vantra.protocol'),
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'requestId')
    ..aOS(2, _omitFieldNames ? '' : 'sourcePeerId')
    ..aOS(3, _omitFieldNames ? '' : 'destinationPeerId')
    ..aI(4, _omitFieldNames ? '' : 'hopCount', fieldType: $pb.PbFieldType.OU3)
    ..aI(5, _omitFieldNames ? '' : 'maxHops', fieldType: $pb.PbFieldType.OU3)
    ..a<$core.List<$core.int>>(
        6, _omitFieldNames ? '' : 'signature', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RouteReply clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RouteReply copyWith(void Function(RouteReply) updates) =>
      super.copyWith((message) => updates(message as RouteReply)) as RouteReply;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static RouteReply create() => RouteReply._();
  @$core.override
  RouteReply createEmptyInstance() => create();
  @$core.pragma('dart2js:noInline')
  static RouteReply getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<RouteReply>(create);
  static RouteReply? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get requestId => $_getSZ(0);
  @$pb.TagNumber(1)
  set requestId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasRequestId() => $_has(0);
  @$pb.TagNumber(1)
  void clearRequestId() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get sourcePeerId => $_getSZ(1);
  @$pb.TagNumber(2)
  set sourcePeerId($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasSourcePeerId() => $_has(1);
  @$pb.TagNumber(2)
  void clearSourcePeerId() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get destinationPeerId => $_getSZ(2);
  @$pb.TagNumber(3)
  set destinationPeerId($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasDestinationPeerId() => $_has(2);
  @$pb.TagNumber(3)
  void clearDestinationPeerId() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.int get hopCount => $_getIZ(3);
  @$pb.TagNumber(4)
  set hopCount($core.int value) => $_setUnsignedInt32(3, value);
  @$pb.TagNumber(4)
  $core.bool hasHopCount() => $_has(3);
  @$pb.TagNumber(4)
  void clearHopCount() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.int get maxHops => $_getIZ(4);
  @$pb.TagNumber(5)
  set maxHops($core.int value) => $_setUnsignedInt32(4, value);
  @$pb.TagNumber(5)
  $core.bool hasMaxHops() => $_has(4);
  @$pb.TagNumber(5)
  void clearMaxHops() => $_clearField(5);

  @$pb.TagNumber(6)
  $core.List<$core.int> get signature => $_getN(5);
  @$pb.TagNumber(6)
  set signature($core.List<$core.int> value) => $_setBytes(5, value);
  @$pb.TagNumber(6)
  $core.bool hasSignature() => $_has(5);
  @$pb.TagNumber(6)
  void clearSignature() => $_clearField(6);
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
