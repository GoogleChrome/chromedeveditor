// Copyright (c) 2014, Google Inc. Please see the AUTHORS file for details.
// All rights reserved. Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

library spark.harness_push;

import 'dart:async';

import 'jobs.dart';
import 'tcp.dart';
import 'workspace.dart';
import 'workspace_utils.dart';

class HarnessPush {
  final Container appContainer;

  HarnessPush(this.appContainer) {
    if (appContainer == null) {
      throw new ArgumentError('must provide an app to push');
    }
  }

  /**
   * Packages (a subdirectory of) the current project, and sends it via HTTP to
   * a remote host.
   *
   * It expects the target host, and a [ProgressMonitor] for 10 units of work.
   * All files under the project will be added to a (slightly broken, see
   * below) CRX file, and sent via HTTP POST to the target host, using the /push
   * protocol described [here](https://github.com/MobileChromeApps/harness-push).
   *
   *     HarnessPush.push('192.168.1.121', monitor);
   *
   * Returns a Future for the push operation.
   *
   * Important Note: The CRX file that gets created and pushed is not correctly
   * signed and does not include the application's key. Since the target of a
   * push is intended to be a tool like the
   * [Chrome ADT](https://github.com/MobileChromeApps/harness) on Android,
   * and that tool doesn't care about the CRX metadata, this is not a problem.
   */
  Future push(String target, ProgressMonitor monitor) {
    monitor.start('Deploying…', 10);

    return archiveContainer(appContainer).then((List<int> archivedData) {
      monitor.worked(3);
      List<int> httpRequest = [];
      // Build the HTTP request headers.
      String boundary = "--------------------------------a921a8f557cf";
      String header = "POST /push?name=${appContainer.name}&type=crx HTTP/1.1\r\n"
          + "User-Agent: Spark IDE\r\n"
          + "Host: ${target}:2424\r\n"
          + "Content-Type: multipart/form-data; boundary=$boundary\r\n";
      List<int> body = [];
      String bodyTop = "$boundary\r\n"
          + "Content-Disposition: form-data; name=\"file\"; "
          + "filename=\"SparkPush.crx\"\r\n"
          + "Content-Type: application/octet-stream\r\n\r\n";
      body.addAll(bodyTop.codeUnits);

      // Add the CRX headers before the zip content.
      // This is the string "Cr24" then three little-endian 32-bit numbers:
      // - The version (2).
      // - The public key length (0).
      // - The signature length (0).
      // Since the App Harness/Chrome ADT on the other end doesn't check
      // the signature or key, we don't bother sending them.
      body.addAll([67, 114, 50, 52, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);

      // Now follows the actual zip data.
      body.addAll(archivedData);
      monitor.worked(4);

      // Add the trailing boundary.
      body.addAll([13, 10]); // \r\n
      body.addAll(boundary.codeUnits);
      // Two trailing hyphens to indicate the final boundary.
      body.addAll([45, 45, 13, 10]); // --\r\n

      httpRequest.addAll(header.codeUnits);
      httpRequest.addAll("Content-length: ${body.length}\r\n\r\n".codeUnits);
      httpRequest.addAll(body);

      monitor.worked(1);

      TcpClient client;
      return TcpClient.createClient(target, 2424).then((TcpClient _client) {
        client = _client;
        client.write(httpRequest);
        return client.stream.timeout(new Duration(minutes: 1)).first;
      }).then((List<int> responseBytes) {
        String response = new String.fromCharCodes(responseBytes);
        List<String> lines = response.split('\n');
        if (lines == null || lines.isEmpty) {
          throw 'Bad response from push server';
        }

        if (lines.first.contains('200')) {
          monitor.worked(2);
        } else {
          throw lines.first;
        }
      }).whenComplete(() {
        if (client != null) {
          client.dispose();
        }
      });
    });
  }
}
