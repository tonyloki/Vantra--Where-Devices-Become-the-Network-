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

import 'package:protobuf/protobuf.dart' as $pb;

class Capability extends $pb.ProtobufEnum {
  static const Capability CAPABILITY_UNSPECIFIED =
      Capability._(0, _omitEnumNames ? '' : 'CAPABILITY_UNSPECIFIED');
  static const Capability CAPABILITY_TEXT =
      Capability._(1, _omitEnumNames ? '' : 'CAPABILITY_TEXT');
  static const Capability CAPABILITY_IMAGE =
      Capability._(2, _omitEnumNames ? '' : 'CAPABILITY_IMAGE');
  static const Capability CAPABILITY_AUDIO =
      Capability._(3, _omitEnumNames ? '' : 'CAPABILITY_AUDIO');
  static const Capability CAPABILITY_VIDEO =
      Capability._(4, _omitEnumNames ? '' : 'CAPABILITY_VIDEO');
  static const Capability CAPABILITY_FILE =
      Capability._(5, _omitEnumNames ? '' : 'CAPABILITY_FILE');
  static const Capability CAPABILITY_GROUP =
      Capability._(6, _omitEnumNames ? '' : 'CAPABILITY_GROUP');

  static const $core.List<Capability> values = <Capability>[
    CAPABILITY_UNSPECIFIED,
    CAPABILITY_TEXT,
    CAPABILITY_IMAGE,
    CAPABILITY_AUDIO,
    CAPABILITY_VIDEO,
    CAPABILITY_FILE,
    CAPABILITY_GROUP,
  ];

  static final $core.List<Capability?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 6);
  static Capability? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const Capability._(super.value, super.name);
}

class DeliveryStatus extends $pb.ProtobufEnum {
  static const DeliveryStatus DELIVERY_UNSPECIFIED =
      DeliveryStatus._(0, _omitEnumNames ? '' : 'DELIVERY_UNSPECIFIED');
  static const DeliveryStatus DELIVERY_DELIVERED =
      DeliveryStatus._(1, _omitEnumNames ? '' : 'DELIVERY_DELIVERED');

  static const $core.List<DeliveryStatus> values = <DeliveryStatus>[
    DELIVERY_UNSPECIFIED,
    DELIVERY_DELIVERED,
  ];

  static final $core.List<DeliveryStatus?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 1);
  static DeliveryStatus? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const DeliveryStatus._(super.value, super.name);
}

const $core.bool _omitEnumNames =
    $core.bool.fromEnvironment('protobuf.omit_enum_names');
