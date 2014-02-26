// Copyright (c) 2014, Google Inc. Please see the AUTHORS file for details.
// All rights reserved. Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

/**
 * This is a separate application spawned by Spark (via Services) as an isolate
 * for use in running long-running / heaving tasks.
 */
library spark.services_impl;

import 'dart:async';
import 'dart:isolate';

import 'lib/services/analyzer.dart';
import 'lib/services/compiler.dart';
import 'lib/dart/sdk.dart';
import 'lib/utils.dart';

void main(List<String> args, SendPort sendPort) {
  // For use with top level print() helper function.
  _printSendPort = sendPort;

  final ServicesIsolate servicesIsolate = new ServicesIsolate(sendPort);
}

/**
 * Defines a handler for all worker-side service implementations.
 */
class ServicesIsolate {
  int _topCallId = 0;
  final SendPort _sendPort;

  // Fired when host originates a message
  Stream<ServiceActionEvent> onHostMessage;

  // Fired when host responds to message
  Stream<ServiceActionEvent> onResponseMessage;

  ChromeService chromeService;
  Map<String, ServiceImpl> _serviceImplsById = {};

  Future<ServiceActionEvent> _onResponseByCallId(String callId) {
    Completer<ServiceActionEvent> completer =
        new Completer<ServiceActionEvent>();
    onResponseMessage.listen((ServiceActionEvent event) {
      try {
        if (event.callId == callId) {
          completer.complete(event);
        }
      } catch(e) {
        printError("Service error", e);
      }
    });
    return completer.future;
  }

  ServicesIsolate(this._sendPort) {
    chromeService = new ChromeService(this);

    StreamController<ServiceActionEvent> hostMessageController =
        new StreamController<ServiceActionEvent>.broadcast();
    StreamController<ServiceActionEvent> responseMessageController =
        new StreamController<ServiceActionEvent>.broadcast();

    onResponseMessage = responseMessageController.stream;
    onHostMessage = hostMessageController.stream;

    // Register each ServiceImpl:
    _registerServiceImpl(new CompilerServiceImpl(this));
    _registerServiceImpl(new ExampleServiceImpl(this));

    ReceivePort receivePort = new ReceivePort();
    _sendPort.send(receivePort.sendPort);

    receivePort.listen((arg) {
      try {
        if (arg is int) {
          _sendPort.send(arg);
        } else {
          ServiceActionEvent event = new ServiceActionEvent.fromMap(arg);
          if (event.response) {
            responseMessageController.add(event);
          } else {
            hostMessageController.add(event);
          }
        }
      } catch(e) {
        printError("Service error", e);
      }
    });

    onHostMessage.listen((ServiceActionEvent event) {
      try {
        _handleMessage(event);
      } catch(e) {
        printError("Service error", e);
      }
    });
  }

  void _registerServiceImpl(ServiceImpl serviceImplementation) {
    _serviceImplsById[serviceImplementation.serviceId] =
        serviceImplementation;
  }

  ServiceImpl getServiceImpl(String serviceId) {
    return _serviceImplsById[serviceId];
  }

  Future<ServiceActionEvent> _handleMessage(ServiceActionEvent event) {
    Completer<ServiceActionEvent> completer =
        new Completer<ServiceActionEvent>();

    ServiceImpl service = getServiceImpl(event.serviceId);
    service.handleEvent(event).then((ServiceActionEvent responseEvent){
      if (responseEvent != null) {
        _sendResponse(responseEvent);
        completer.complete();
      }
    }).catchError((e) {
      printError("Service error", e);
    });
    return completer.future;
  }

  // Sends a response message.
  void _sendResponse(ServiceActionEvent event, [Map data,
      bool expectResponse = false]) {
    // TODO(ericarnold): implement expectResponse
    event.response = true;
    var eventMap = event.toMap();
    if (data != null) {
      eventMap['data'] = data;
    }
    _sendPort.send(eventMap);
  }

  String _getNewCallId() => "iso_${_topCallId++}";

  // Sends action to host.  Returns a future if expectResponse is true.
  Future<ServiceActionEvent> _sendAction(ServiceActionEvent event,
      [bool expectResponse = false]) {

    event.makeRespondable(_getNewCallId());

    var eventMap = event.toMap();
    _sendPort.send(eventMap);
    return _onResponseByCallId(event.callId);
  }
}

class ExampleServiceImpl extends ServiceImpl {
  String get serviceId => "example";
  ExampleServiceImpl(ServicesIsolate isolate) : super(isolate);

  Future<ServiceActionEvent> handleEvent(ServiceActionEvent event) {
    switch (event.actionId) {
      case "shortTest":
        return new Future.value(event.createReponse(
            {"response": "short${event.data['name']}"}));
        break;
      case "readText":
        String fileUuid = event.data['fileUuid'];
        return _isolate.chromeService.getFileContents(fileUuid)
            .then((String contents) =>
                event.createReponse({"contents": contents}));
        break;
      case "longTest":
        return _isolate.chromeService.delay(1000).then((_){
          return new Future.value(event.createReponse(
              {"response": "long${event.data['name']}"}));
        });
      default:
        throw "Unknown action '${event.actionId}' sent to $serviceId service.";
    }
  }
}


class CompilerServiceImpl extends ServiceImpl {
  String get serviceId => "compiler";

  DartSdk sdk;
  Compiler compiler;

  Completer<ServiceActionEvent> _readyCompleter =
      new Completer<ServiceActionEvent>();

  Future<ServiceActionEvent> get onceReady => _readyCompleter.future;

  CompilerServiceImpl(ServicesIsolate isolate) : super(isolate);

  Future<ServiceActionEvent> handleEvent(ServiceActionEvent event) {
    switch (event.actionId) {
      case "start":
        // TODO(ericarnold): Start should happen automatically on use.
        return _start().then((_) => new Future.value(event.createReponse(null)));
        break;
      case "dispose":
        return new Future.value(event.createReponse(null));
        break;
      case "compileString":
        return compiler.compileString(event.data['string'])
            .then((CompilerResult result)  {
              return new Future.value(event.createReponse(result.toMap()));
            });
        break;
      default:
        throw "Unknown action '${event.actionId}' sent to $serviceId service.";
    }
  }

  Future _start() {
    _isolate.chromeService.getAppContents('sdk/dart-sdk.bin').then((List<int> sdkContents) {
      sdk = DartSdk.createSdkFromContents(sdkContents);
      compiler = Compiler.createCompilerFrom(sdk);
      _readyCompleter.complete();
    }).catchError((e){
      // TODO(ericarnold): Return error which service will throw
      printError("Chrome service error", e);
    });

    return _readyCompleter.future;
  }
}

class AnalyzerServiceImpl extends ServiceImpl {
  String get serviceId => "analyzer";
  Analyzer

  Future<ServiceActionEvent> handleEvent(ServiceActionEvent event) {
    switch (event.actionId) {
      case "start":

        break;
      case "analyzeString":
        analyzer.createSdk().then((int sdkId) {
          return Future.forEach(dartFiles, (file) => _processFile(sdkId, file))
        }).then((_) => completer.complete());


        break;
  }

  Future build() {
    Completer completer = new Completer();

    createSdk().then((ChromeDartSdk sdk) {
      Future.forEach(dartFiles, (file) => _processFile(sdk, file)).then((_) {
        completer.complete();
      });
    });

    return completer.future;
  }

  /**
   * Create markers for a `.dart` file.
   */
  Future _processFile(ChromeDartSdk sdk, File file) {
    return file.getContents().then((String contents) {
      return analyzeString(sdk, contents, performResolution: false).then((AnalyzerResult result) {
        file.workspace.pauseMarkerStream();

        try {
          file.clearMarkers();

          for (AnalysisError error in result.errors) {
            LineInfo_Location location = result.getLineInfo(error);

            file.createMarker(
                'dart', _convertSeverity(error.errorCode.errorSeverity),
                error.message, location.lineNumber,
                error.offset, error.offset + error.length);
          }
        } finally {
          file.workspace.resumeMarkerStream();
        }
      });
    });
  }

}

/**
 * Special service for calling back to chrome.
 */
class ChromeService {
  ServicesIsolate _isolate;

  ChromeService(this._isolate);

  ServiceActionEvent _createNewEvent(String actionId, [Map data]) {
    return new ServiceActionEvent("chrome", actionId, data);
  }

  Future<ServiceActionEvent> delay(int milliseconds) =>
      _sendAction(_createNewEvent("delay", {"ms": milliseconds}));

  /**
   * Return the contents of the file at the given path. The path is relative to
   * the Chrome app's directory.
   */
  Future<List<int>> getAppContents(String path) {
    return _sendAction(_createNewEvent("getAppContents", {"path": path}))
        .then((ServiceActionEvent event) => event.data['contents']);
  }

  Future<String> getFileContents(String uuid) =>
    _sendAction(_createNewEvent("getFileContents", {"uuid": uuid}))
        .then((ServiceActionEvent event) => event.data["contents"]);

  Future<ServiceActionEvent> _sendAction(ServiceActionEvent event,
      [bool expectResponse = false]) {
    return _isolate._sendAction(event, expectResponse)
        .then((ServiceActionEvent event){
          if (event.error != true) {
            return event;
          } else {
            String error = event.data['error'];
            String stackTrace = event.data['stackTrace'];
            throw "ChromeService error: $error\n$stackTrace";
          }
        });
  }
}

// Provides an abstract class and helper code for service implementations.
abstract class ServiceImpl {
  ServicesIsolate _isolate;

  ServiceImpl(this._isolate);

  String get serviceId;

  Future<ServiceActionEvent> handleEvent(ServiceActionEvent event);
}

// Prints are crashing isolate, so this will take over for the time being.
SendPort _printSendPort;

void print(var message) {
  // Host will know it's a print because it's a simple string instead of a map
  if (_printSendPort != null) {
    _printSendPort.send("$message");
  }
}

printError(String description, dynamic e) {
  String stackTrace;
  try {
    stackTrace = "\n${e.stackTrace}";
  } catch(e) {
    stackTrace = "";
  }

  print ("$description $e $stackTrace");
}



