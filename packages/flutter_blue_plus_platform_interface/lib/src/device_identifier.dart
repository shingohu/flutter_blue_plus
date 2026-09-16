class DeviceIdentifier {
  final String str;

  const DeviceIdentifier(this.str);

  @override
  String toString() => str;

  @override
  int get hashCode => str.hashCode;

  @override
  bool operator ==(Object other) => identical(this, other) || other is DeviceIdentifier && str == other.str;
}
