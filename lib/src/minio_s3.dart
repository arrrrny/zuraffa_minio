const awsS3Endpoint = {
  'af-south-1': 's3.af-south-1.amazonaws.com',
  'ap-east-1': 's3.ap-east-1.amazonaws.com',
  'ap-northeast-1': 's3-ap-northeast-1.amazonaws.com',
  'ap-northeast-2': 's3.ap-northeast-2.amazonaws.com',
  'ap-northeast-3': 's3.ap-northeast-3.amazonaws.com',
  'ap-south-1': 's3-ap-south-1.amazonaws.com',
  'ap-south-2': 's3.ap-south-2.amazonaws.com',
  'ap-southeast-1': 's3-ap-southeast-1.amazonaws.com',
  'ap-southeast-2': 's3-ap-southeast-2.amazonaws.com',
  'ap-southeast-3': 's3.ap-southeast-3.amazonaws.com',
  'ap-southeast-4': 's3.ap-southeast-4.amazonaws.com',
  'ap-southeast-5': 's3.ap-southeast-5.amazonaws.com',
  'ca-central-1': 's3.ca-central-1.amazonaws.com',
  'ca-west-1': 's3.ca-west-1.amazonaws.com',
  'cn-north-1': 's3.cn-north-1.amazonaws.com.cn',
  'cn-northwest-1': 's3.cn-northwest-1.amazonaws.com.cn',
  'eu-central-1': 's3-eu-central-1.amazonaws.com',
  'eu-central-2': 's3.eu-central-2.amazonaws.com',
  'eu-north-1': 's3.eu-north-1.amazonaws.com',
  'eu-south-1': 's3.eu-south-1.amazonaws.com',
  'eu-south-2': 's3.eu-south-2.amazonaws.com',
  'eu-west-1': 's3-eu-west-1.amazonaws.com',
  'eu-west-2': 's3-eu-west-2.amazonaws.com',
  'eu-west-3': 's3.eu-west-3.amazonaws.com',
  'il-central-1': 's3.il-central-1.amazonaws.com',
  'me-central-1': 's3.me-central-1.amazonaws.com',
  'me-south-1': 's3.me-south-1.amazonaws.com',
  'sa-east-1': 's3-sa-east-1.amazonaws.com',
  'us-east-1': 's3.amazonaws.com',
  'us-east-2': 's3-us-east-2.amazonaws.com',
  'us-west-1': 's3-us-west-1.amazonaws.com',
  'us-west-2': 's3-us-west-2.amazonaws.com',
};

/// The AWS partition a [region] belongs to.
///
/// China regions live under a separate domain (`amazonaws.com.cn`) and have
/// their own key set, so the endpoint cannot be derived from the region name
/// alone.
bool isChinaRegion(String region) {
  return region.startsWith('cn-');
}

/// getS3Endpoint get relevant endpoint for the region.
///
/// Upstream fell back to the global `s3.amazonaws.com` for every region that
/// was missing from its hard-coded table. That fallback is a trap: the global
/// endpoint only accepts `us-east-1` signatures, so a request signed for, say,
/// `ap-southeast-4` is rejected by AWS with
///
///     The authorization header is malformed; the region is wrong;
///     expecting 'us-east-1'.
///
/// (upstream issue #38). Unknown regions now get their canonical regional
/// host instead, which is what the signature actually claims.
String getS3Endpoint(String region) {
  final endpoint = awsS3Endpoint[region];
  if (endpoint != null) return endpoint;
  if (isChinaRegion(region)) return 's3.$region.amazonaws.com.cn';
  return 's3.$region.amazonaws.com';
}
