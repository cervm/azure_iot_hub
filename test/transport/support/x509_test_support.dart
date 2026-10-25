import 'dart:io';

import 'device_test_support.dart';

const deviceChain = 'test/transport/fixtures/device-chain.pem';
const deviceKey = 'test/transport/fixtures/device-key.pem';
const deviceRoot = 'test/transport/fixtures/device-root-ca.pem';

SecurityContext x509ClientContext() => clientContext()
  ..useCertificateChain(deviceChain)
  ..usePrivateKey(deviceKey);

SecurityContext x509ServerContext() => serverContext()
  ..setTrustedCertificates(deviceRoot)
  ..setClientAuthorities(deviceRoot);
