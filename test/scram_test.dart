import 'package:flutter_test/flutter_test.dart';
import 'package:netmeter/core/huawei_client.dart';

void main() {
  // Expected values come from the router's own emui-crypto.js (CryptoJS SCRAM), run in node with the same inputs.
  test('SCRAM matches the router CryptoJS', () {
    final r = scram('correct horse', 'aabbccddeeff00112233445566778899', 100, 'n1,n1s,n1s');
    expect(r.proof, 'b82641f8a552a03e4378a764699ce9f01f761577cf7e97652459bfc99fcc78f9');
    expect(r.serverSignature, 'd5bb10055cb792c6f78973c0a47ff78a876a7fba85f623f17b116cc5bc2d6689');
  });
}
