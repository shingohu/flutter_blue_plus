import 'package:flutter_blue_plus_android/flutter_blue_plus_android.dart';
import 'support/characteristic_operations_suite.dart';

void main() => characteristicOperationsSuite(
    'Android Dart adapter', FlutterBluePlusAndroid.new);
