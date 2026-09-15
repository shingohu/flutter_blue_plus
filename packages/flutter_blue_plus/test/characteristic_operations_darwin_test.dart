import 'package:flutter_blue_plus_darwin/flutter_blue_plus_darwin.dart';
import 'support/characteristic_operations_suite.dart';

void main() => characteristicOperationsSuite(
    'Darwin Dart adapter', FlutterBluePlusDarwin.new);
