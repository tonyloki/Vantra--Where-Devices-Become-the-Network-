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

enum VantraWireEnvelope_Payload { handshake, encryptedMessage, error, notSet }

/// Top-level wire message sent across Transport
class VantraWireEnvelope extends $pb.GeneratedMessage {
  factory VantraWireEnvelope({
    $core.int? protocolVersion,
    IdentitySecurePayload? handshake,
    EncryptedEnvelope? encryptedMessage,
    ProtocolErrorPayload? error,
  }) {
    final result = create();
    if (protocolVersion != null) result.protocolVersion = protocolVersion;
    if (handshake != null) result.handshake = handshake;
    if (encryptedMessage != null) result.encryptedMessage = encryptedMessage;
    if (error != null) result.error = error;
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
    0: VantraWireEnvelope_Payload.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'VantraWireEnvelope',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'vantra.protocol'),
      createEmptyInstance: create)
    ..oo(0, [2, 3, 4])
    ..aI(1, _omitFieldNames ? '' : 'protocolVersion',
        fieldType: $pb.PbFieldType.OU3)
    ..aOM<IdentitySecurePayload>(2, _omitFieldNames ? '' : 'handshake',
        subBuilder: IdentitySecurePayload.create)
    ..aOM<EncryptedEnvelope>(3, _omitFieldNames ? '' : 'encryptedMessage',
        subBuilder: EncryptedEnvelope.create)
    ..aOM<ProtocolErrorPayload>(4, _omitFieldNames ? '' : 'error',
        subBuilder: ProtocolErrorPayload.create)
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
  VantraWireEnvelope_Payload whichPayload() =>
      _VantraWireEnvelope_PayloadByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  @$pb.TagNumber(4)
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
}

/// 1. Handshake Payload (Unencrypted wire format during initial connection)
class IdentitySecurePayload extends $pb.GeneratedMessage {
  factory IdentitySecurePayload({
    $core.String? peerId,
    $core.String? displayName,
    $core.List<$core.int>? identityPublicKey,
    $core.List<$core.int>? ephemeralPublicKey,
    $core.List<$core.int>? signature,
  }) {
    final result = create();
    if (peerId != null) result.peerId = peerId;
    if (displayName != null) result.displayName = displayName;
    if (identityPublicKey != null) result.identityPublicKey = identityPublicKey;
    if (ephemeralPublicKey != null)
      result.ephemeralPublicKey = ephemeralPublicKey;
    if (signature != null) result.signature = signature;
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

enum VantraPlaintext_Body { text, ack, notSet }

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
    0: VantraPlaintext_Body.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'VantraPlaintext',
      package:
          const $pb.PackageName(_omitMessageNames ? '' : 'vantra.protocol'),
      createEmptyInstance: create)
    ..oo(0, [7, 8])
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
  VantraPlaintext_Body whichBody() =>
      _VantraPlaintext_BodyByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(7)
  @$pb.TagNumber(8)
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

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
