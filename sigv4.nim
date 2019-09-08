import os
import httpcore
import json
import strutils
import uri
import algorithm
import sequtils
import tables
import times

import nimcrypto/sha2 as sha
import nimcrypto/hash as md
import nimcrypto/hmac as hmac

const
  dateISO8601 = initTimeFormat "yyyyMMdd"
  tightISO8601 = initTimeFormat "yyyyMMdd\'T\'HHmmss\'Z\'"

type
  PathNormal* = enum
    Default ## normalize paths to dereference `.` and `..` and de-dupe `/`
    S3 ## do not normalize paths, and perform one less pass of escaping
  SigningAlgo* = enum
    SHA256 = "AWS4-HMAC-SHA256"
    SHA512 = "AWS4-HMAC-SHA512"
  DigestTypes = md.MDigest[256] | md.MDigest[512]

proc encodedSegment(segment: string; passes: int): string =
  ## encode a segment 1+ times
  result = segment.encodeUrl(usePlus = false)
  if passes > 1:
    result = result.encodedSegment(passes - 1)

proc encodedComponents(path: string; passes: int): string =
  ## encode an entire path with a number of passes
  if '/' notin path:
    return path.encodedSegment(passes)
  let
    splat = path.splitPath
    tail = splat.tail.encodedSegment(passes)
  result = splat.head.encodedComponents(passes) & "/" & tail

proc encodedPath(path: string; style: PathNormal): string =
  ## normalize and encode a URI's path
  case style:
  of S3:
    result = path
    result = result.encodedComponents(passes=1)
  of Default:
    result = path.normalizedPath
    if path.endsWith("/") and not result.endsWith("/"):
      result = result & "/"
    result = result.encodedComponents(passes=2)
  if not result.startsWith("/"):
    result = "/" & result

proc encodedPath(uri: Uri; style: PathNormal): string =
  ## normalize and encode a URI's path
  result = uri.path.encodedPath(style)

proc encodedQuery(input: openarray[tuple[key: string, val: string]]): string =
  ## encoded a series of key/value pairs as a query string
  let query = input.sortedByIt (it.key, it.val)
  for key, value in query.items:
    if result.len > 0:
      result &= "&"
    result &= encodeUrl(key, usePlus = false)
    result &= "="
    result &= encodeUrl(value, usePlus = false)

proc toQueryValue(node: JsonNode): string =
  assert node != nil
  result = case node.kind:
  of JString: node.getStr
  of JInt, JFloat, JBool: $node
  of JNull: ""
  else:
    raise newException(ValueError, $node.kind & " unsupported")

proc encodedQuery(node: JsonNode): string =
  ## convert a JsonNode into an encoded query string
  var query: seq[tuple[key: string, val: string]]
  assert node != nil and node.kind == JObject
  if node == nil or node.kind != JObject:
    raise newException(ValueError, "pass me a JObject")
  for k, v in node.pairs:
    query.add (key: k, val: v.toQueryValue)
  result = encodedQuery(query)

proc trimAll(s: string): string =
  ## remove surrounding whitespace and de-dupe internal spaces
  result = s.strip(leading=true, trailing=true)
  while "  " in result:
    result = result.replace("  ", " ")

proc encodedHeaders(headers: HttpHeaders): tuple[signed: string; canonical: string] =
  ## convert http headers into encoded header string
  var
    signed, canonical: string
    heads: seq[tuple[key: string, val: string]]
  if headers == nil:
    return (signed: "", canonical: "")
  for k, v in headers.table.pairs:
    heads.add (key: k.strip.toLowerAscii,
               val: v.map(trimAll).join(","))
  heads = heads.sortedByIt (it.key)
  for h in heads:
    if signed.len > 0:
      signed &= ";"
    signed &= h.key
    canonical &= h.key & ":" & h.val & "\n"
  result = (signed: signed, canonical: canonical)

proc signedHeaders*(headers: HttpHeaders): string =
  ## calculate the list of signed headers
  var encoded = headers.encodedHeaders
  result = encoded.signed

when defined(nimcryptoLowercase):
  proc toLowerHex(digest: DigestTypes): string =
    result = $digest
else:
  proc toLowerHex(digest: DigestTypes): string =
    {.hint: "sigv4: set -d:nimcryptoLowercase".}
    # ...in order to optimize out the following call...
    result = toLowerAscii($digest)

when defined(debug):
  converter toString(digest: md.MDigest[256]): string = digest.toLowerHex
  converter toString(digest: md.MDigest[512]): string = digest.toLowerHex

proc hash*(payload: string; digest: SigningAlgo): string =
  ## hash an arbitrary string using the given algorithm
  case digest:
  of SHA256: result = md.digest(sha.sha256, payload).toLowerHex
  of SHA512: result = md.digest(sha.sha512, payload).toLowerHex

proc canonicalRequest*(meth: HttpMethod;
                      url: string;
                      query: JsonNode;
                      headers: HttpHeaders;
                      payload: string;
                      normalize: PathNormal = Default;
                      digest: SigningAlgo = SHA256): string =
  ## produce the canonical request for signing purposes
  let
    httpmethod = $meth
    uri = url.parseUri
    (signedHeaders, canonicalHeaders) = headers.encodedHeaders()

  result = httpmethod.toUpperAscii & "\n"
  result &= uri.encodedPath(normalize) & "\n"
  result &= query.encodedQuery() & "\n"
  result &= canonicalHeaders & "\n"
  result &= signedHeaders & "\n"
  result &= hash(payload, digest)

proc credentialScope*(region: string; service: string; date= ""): string =
  ## combine region, service, and date into a scope
  var d = date[.. (len("YYYYMMDD")-1)]
  if d == "":
    d = getTime().utc.format(dateISO8601)
  result = d / region.toLowerAscii / service.toLowerAscii / "aws4_request"

proc stringToSign*(hash: string; scope: string; date= ""; digest: SigningAlgo = SHA256): string =
  ## combine signing algo, payload hash, credential scope, and date
  var d = date
  if d == "":
    d = getTime().utc.format(tightISO8601)
  assert d["YYYYMMDD".len] == 'T'
  assert d["YYYYMMDDTHHMMSS".len] == 'Z'
  result = $digest & "\n"
  result &= d[.. ("YYYYMMDDTHHMMSSZ".len-1)] & "\n"
  result &= scope & "\n"
  result &= hash

proc deriveKey(H: typedesc; secret: string; date: string;
                region: string; service: string): md.MDigest[H.bits] =
  ## compute the signing key for a subsequent signature
  var
    digest = hmac.hmac(H, "AWS4" & secret, date[.. (len("YYYYMMDD")-1)])
  digest = hmac.hmac(H, digest.data, region.toLowerAscii)
  digest = hmac.hmac(H, digest.data, service.toLowerAscii)
  digest = hmac.hmac(H, digest.data, "aws4_request")
  result = digest

#proc calculateSignature[B: static[int]](H: typedesc; key: md.MDigest[B]; tosign: string): md.MDigest[H.bits] =
#  result = hmac.hmac(H, key.data, tosign)

proc calculateSignature(key: md.MDigest[256]; tosign: string): md.MDigest[256] =
  result = hmac.hmac(sha.sha256, key.data, tosign)

proc calculateSignature(key: md.MDigest[512]; tosign: string): md.MDigest[512] =
  result = hmac.hmac(sha.sha512, key.data, tosign)

proc calculateSignature*(secret: string; date: string; region: string;
                         service: string; tosign: string;
                         digest: SigningAlgo = SHA256): string =
  ## compute a signature using secret, string-to-sign, and other details
  case digest:
  of SHA256:
    var key = deriveKey(sha.sha256, secret, date, region, service)
    result = calculateSignature(key, tosign).toLowerHex
  of SHA512:
    var key = deriveKey(sha.sha512, secret, date, region, service)
    result = calculateSignature(key, tosign).toLowerHex

when isMainModule:
  import unittest

  suite "sig v4":
    setup:
      let
        url = "https://iam.amazonaws.com/?Action=ListUsers&Version=2010-05-08"
        secret = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
        region = "us-east-1"
        service = "iam"
        digest = SHA256
        normal = Default
        date = "20150830T123600Z"
        q = %* {
          "Action": "ListUsers",
          "Version": "2010-05-08",
        }
        heads = @[
          ("Host", "iam.amazonaws.com"),
          ("Content-Type", "application/x-www-form-urlencoded; charset=utf-8"),
          ("X-Amz-Date", date),
        ]
        c = credentialScope(region=region, service=service, date=date)
        pay = "sigv4 test"
        e = {
          "AWS4-HMAC-SHA256": "474fff1f1f31f629b3a8932f1020ad2e73bf82e08c96d5998de39d66c8867836",
          "AWS4-HMAC-SHA512": "1dee518b5b2479e9fa502c05d4726a40bade650adbc391da8f196797df0f5da62e0659ad0e5a91e185c4b047d7a2d6324fae493a0abdae7aa10b09ec8303f6fe",
        }.toTable
      var h: HttpHeaders = newHttpHeaders(heads)
    test "encoded segment":
      check "".encodedSegment(passes=1) == ""
      check "foo".encodedSegment(passes=1) == "foo"
      check "foo".encodedSegment(passes=2) == "foo"
      check "foo bar".encodedSegment(passes=1) == "foo%20bar"
      check "foo bar".encodedSegment(passes=2) == "foo%2520bar"
    test "encoded components":
      check "/".encodedComponents(passes=1) == "/"
      check "//".encodedComponents(passes=1) == "//"
      check "foo".encodedComponents(passes=1) == "foo"
      check "/foo/bar".encodedComponents(passes=1) == "/foo/bar"
      check "/foo/bar/".encodedComponents(passes=1) == "/foo/bar/"
      check "/foo bar".encodedComponents(passes=1) == "/foo%20bar"
      check "/foo bar/".encodedComponents(passes=2) == "/foo%2520bar/"
      check "foo bar".encodedComponents(passes=2) == "foo%2520bar"
      check "foo bar/bif".encodedComponents(passes=2) == "foo%2520bar/bif"
    test "encoded path":
      check "/".encodedPath(Default) == "/"
      check "/".encodedPath(S3) == "/"
      check "//".encodedPath(Default) == "/"
      check "//".encodedPath(S3) == "//"
      check "foo bar".encodedPath(Default) == "/foo%2520bar"
      check "foo bar//../bif baz".encodedPath(Default) == "/bif%2520baz"
      check "/foo bar/bif/".encodedPath(Default) == "/foo%2520bar/bif/"
      check "/foo bar//../bif".encodedPath(S3) == "/foo%20bar//../bif"
      check "/foo bar//../bif/".encodedPath(S3) == "/foo%20bar//../bif/"
    test "encoded query":
      let
        cq = %* {
          "a": 1,
          "B": 2.0,
          "c": newJNull(),
          "3 4": "5,🙄",
        }
      check cq.encodedQuery == "3%204=5%2C%F0%9F%99%84&B=2.0&a=1&c="
      check q.encodedQuery == "Action=ListUsers&Version=2010-05-08"
    test "encoded headers":
      var
        rheads = heads.reversed
        r: tuple[signed: string; canonical: string]
      r = (signed: "content-type;host;x-amz-date",
           canonical: "content-type:application/x-www-form-urlencoded; charset=utf-8\nhost:iam.amazonaws.com\nx-amz-date:20150830T123600Z\n")
      h = newHttpHeaders(heads)
      check r == h.encodedHeaders()
      h = newHttpHeaders(rheads)
      check r == h.encodedHeaders()
    test "signing algos":
      check pay.hash(SHA256) == e[$SHA256]
      check pay.hash(SHA512) == e[$SHA512]
      check "".hash(SHA256) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    test "canonical request":
      # example from amazon
      discard """
      GET https://iam.amazonaws.com/?Action=ListUsers&Version=2010-05-08 HTTP/1.1
Host: iam.amazonaws.com
Content-Type: application/x-www-form-urlencoded; charset=utf-8
X-Amz-Date: 20150830T123600Z
      """
      let
        ch = newHttpHeaders(heads)
        cq = %* {
          "Action": "ListUsers",
          "Version": "2010-05-08",
        }
        canonical = canonicalRequest(HttpGet, url, q, h, "", normal, digest)
        x = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        y = "f536975d06c0309214f805bb90ccff089219ecd68b2577efef23edd43b7e1a59"
      check canonical == """GET
/
Action=ListUsers&Version=2010-05-08
content-type:application/x-www-form-urlencoded; charset=utf-8
host:iam.amazonaws.com
x-amz-date:20150830T123600Z

content-type;host;x-amz-date
""" & x
      check canonical.hash(digest) == y
    test "credential scope":
      let
        d = "2020010155555555555"
        scope = credentialScope(region="Us-West-1", service="IAM", date=d)
        skope = credentialScope(region=region, service=service, date=date)
      check scope == "20200101/us-west-1/iam/aws4_request"
      check skope == "20150830/us-east-1/iam/aws4_request"
    test "string to sign":
      let
        req = canonicalRequest(HttpGet, url, q, h, "", normal, digest)
        x = "f536975d06c0309214f805bb90ccff089219ecd68b2577efef23edd43b7e1a59"
        scope = credentialScope(region=region, service=service, date=date)
        sts = stringToSign(req.hash(digest), scope, date=date, digest=digest)
      check req.hash(digest) == x
      check sts == """AWS4-HMAC-SHA256
20150830T123600Z
20150830/us-east-1/iam/aws4_request
""" & x
    test "derive key":
      let
        key = deriveKey(sha.sha256, secret, date=date,
                        region=region, service=service)
        x = "c4afb1cc5771d871763a393e44b703571b55cc28424d1a5e86da6ed3c154a4b9"
      check x == key.toLowerHex
    test "calculate signature":
      let
        req = canonicalRequest(HttpGet, url, q, h, "", normal, digest)
        scope = credentialScope(region=region, service=service, date=date)
        sts = stringToSign(req.hash(digest), scope, date=date, digest=digest)
        key = deriveKey(sha.sha256, secret, date=date,
                        region=region, service=service)
        x = "5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7"
      check x == calculateSignature(key, sts).toLowerHex
      check x == calculateSignature(secret=secret, date=date, region=region,
                                    service=service, tosign=sts, digest=digest)
