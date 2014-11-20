// Copyright (c) 2013, Google Inc. Please see the AUTHORS file for details.
// All rights reserved. Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

/**
 * A library to manage the list of open editors, and persist their state (like
 * their selection and scroll position) across sessions.
 */
library spark.editors;

import 'dart:async';
import 'dart:convert' show JSON;
import 'dart:html' as html;

import 'ace.dart' as ace;
import 'event_bus.dart';
import 'navigation.dart';
import 'preferences.dart';
import 'workspace.dart';
import 'services.dart';
import 'ui/widgets/imageviewer.dart';
import 'utils.dart';

// The auto-save delay - the time from the last user edit to the file auto-save.
const int _DELAY_MS = 1000;

/**
 * Classes implement this interface provides/refreshes editors for [Resource]s.
 */
abstract class EditorProvider {
  Editor createEditorForContentProvider(ContentProvider contentProvider);
  void activate(Editor editor);
  void close(ContentProvider contentProvider);
}

/**
 * An abstract Editor class. It knows:
 *
 *  * the main DOM element it's associated with
 *  * the File it's editing
 *
 * In the future, it will know how to save and restore its session state.
 */
abstract class Editor {
  html.Element get element;
  ContentProvider get contentProvider;
  bool get dirty;

  Stream get onDirtyChange;
  Stream get onModification;
  Future<Editor> get whenReady;

  void activate();
  void deactivate();
  void resize();
  void focus();
  void fileContentsChanged();
  Future save();
}

/**
 * An event broadcast by EditorManager to let all interested parties know
 * that a file has been modified.
 */
class FileModifiedBusEvent extends BusEvent {
  // TODO(ussuri): Later on, it may make sense to send a single bulk
  // notification when multiple files get modified at the same time,
  // e.g. during large refactoring.
  final File file;

  FileModifiedBusEvent(this.file);
  BusEventType get type => BusEventType.EDITOR_MANAGER__FILE_MODIFIED;
}

/**
 * Manage a list of open editors.
 */
class EditorManager implements EditorProvider, NavigationLocationProvider {
  final Workspace _workspace;
  final ace.AceManager _aceContainer;
  final SparkPreferences _prefs;
  final EventBus _eventBus;

  StreamController _newFileOpenedController = new StreamController.broadcast();
  Stream get onNewFileOpened => _newFileOpenedController.stream;

  static final int PREFS_EDITORSTATES_VERSION = 1;

  static final int EDITOR_TYPE_IMAGE = 1;
  static final int EDITOR_TYPE_TEXT = 2;

  // List of files opened in a tab.
  final List<_EditorState> _openedEditorStates = [];
  // Keep state of files that have been opened earlier.
  // Keys are persist tokens of the files.
  final Map<String, _EditorState> _savedEditorStates = {};
  List<String> persistedFilesUuids = [];
  final Map<String, Editor> _editorUuidMap = {};
  final Services _services;

  final Completer<bool> _loadedCompleter = new Completer.sync();
  _EditorState _currentState;

  final StreamController<ContentProvider> _selectedController =
      new StreamController.broadcast();

  EditorManager(this._workspace, this._aceContainer, this._prefs,
      this._eventBus, this._services) {

    // TODO(ericarnold): This is temporary.  Everything should use
    // [SparkPreferences]
    _workspace.whenAvailable().then((_) {
      _restoreState().then((_) {
        _loadedCompleter.complete(true);
      });
      _workspace.onResourceChange.listen((ResourceChangeEvent event) {
        // TODO(dvh): reflect name change instead of closing the file.
        event =
            new ResourceChangeEvent.fromList(event.changes, filterRename: true);
        for (ChangeDelta delta in event.changes) {
          if (delta.isDelete) {
            _handleFileDeleted(delta.resource);
            if (delta.deletions.isNotEmpty) {
              for (ChangeDelta change in delta.deletions) {
                _handleFileDeleted(change.resource);
              }
            }
          } else if (delta.isChange && delta.resource.isFile) {
            _handleFileChanged(delta.resource);
          }
        }
      });
    });
  }

  PreferenceStore get _prefStore => _prefs.prefsStore;

  ContentProvider get currentProvider =>
      _currentState != null ? _currentState.contentProvider : null;
  Editor get currentEditor => getEditor(currentProvider);

  Iterable<ContentProvider> get contentProviders =>
      _openedEditorStates.map((_EditorState s) => s.contentProvider);
  Future<bool> get loaded => _loadedCompleter.future;
  Iterable<Editor> get editors => _editorUuidMap.values;
  Editor getEditor(ContentProvider contentProvider) =>
      _editorUuidMap[contentProvider.uuid];

  Stream<ContentProvider> get onSelectedChange => _selectedController.stream;

  void _insertState(_EditorState state) {
    _openedEditorStates.add(state);
    _savedEditorStates[state.contentProvider.uuid] = state;
  }

  bool _removeState(_EditorState state) => _openedEditorStates.remove(state);

  /**
   * This will open the given [File]. If this file is already open, it will
   * instead be made the active editor.
   */
  void openFile(ContentProvider contentProvider, {bool activateEditor: true}) {
    if (contentProvider == null) return;
    _EditorState state = _getStateForUuid(contentProvider.uuid);

    if (state == null) {
      state = _savedEditorStates[contentProvider.uuid];
      if (state == null) {
        state = new _EditorState.fromContentProvider(this, contentProvider);
      }
      _insertState(state);
    }

    if (activateEditor) {
      _switchState(state);
    }
  }

  bool isContentProviderOpened(ContentProvider contentProvider) =>
      _getStateForUuid(contentProvider.uuid) != null;

  bool isFileOpened(File file) =>
      _getStateForUuid(file.uuid) != null;

  void saveAll() => _saveAll(userAction: true);

  void close(ContentProvider contentProvider) {
    _EditorState state = _getStateForUuid(contentProvider.uuid);
    Editor editor = _editorUuidMap[contentProvider.uuid];

    if (state != null) {
      int index = _openedEditorStates.indexOf(state);
      state.updateState();
      _removeState(state);

      if (editor.dirty) {
        editor.save();
      }

      if (_currentState == state) {
        // Switch to the next editor.
        if (_openedEditorStates.isEmpty) {
          _switchState(null);
        } else if (index < _openedEditorStates.length){
          _switchState(_openedEditorStates[index]);
        } else {
          _switchState(_openedEditorStates[index - 1]);
        }
      }

      _editorUuidMap.remove(contentProvider.uuid);

      persistState();
      state.close();
    }
  }

  // Save state of the editor manager.
  void persistState() {
    // The value of the pref is a map. The format is the following:
    // openedTabs: [ ... ] -> list of persist token of the opened files.
    // filesState: [ ... ] -> list of states of previously opened files: known
    //     files.
    // version: 1 -> PREFS_EDITORSTATES_VERSION. The version number helps
    //     ensure that the format is valid.
    Map savedMap = {};
    Set<String> persistedTabs = new Set();
    persistedTabs.addAll(persistedFilesUuids);
    List<String> openedTabs = [];
    // Save only persisted tabs.
    for(_EditorState state in _openedEditorStates) {
      if (persistedTabs.contains(state.contentProvider.uuid)) {
        openedTabs.add(state.contentProvider.uuid);
      }
    }
    savedMap['openedTabs'] = openedTabs;
    List<Map> filesState = [];
    _savedEditorStates.forEach((String key, _EditorState value) {
      filesState.add(value.toMap());
    });
    savedMap['filesState'] = filesState;
    savedMap['version'] = PREFS_EDITORSTATES_VERSION;
    _prefStore.setValue('editorStates', JSON.encode(savedMap));
  }

  // Restore state of the editor manager.
  Future _restoreState() {
    return _prefStore.getValue('editorStates').then((String data) {
      if (data != null) {
        Map savedMap = JSON.decode(data);
        if (savedMap is Map) {
          int version = savedMap['version'];
          if (version == PREFS_EDITORSTATES_VERSION) {
            List<String> openedTabs = savedMap['openedTabs'];
            List<Map> filesState = savedMap['filesState'];
            // Restore state of known files.
            filesState.forEach((Map m) {
              _EditorState state = new _EditorState.fromMap(this, m);
              if (state != null) {
                _savedEditorStates[m['file']] = state;
              }
            });
            // Restore opened files.
            for (String persistId in openedTabs) {
              ContentProvider contentProvider;
              if (persistId.startsWith("PreferenceContentProvider")) {
                contentProvider = new PreferenceContentProvider(_prefs.prefsStore,
                    persistId);
              } else {
                File file = _workspace.restoreResource(persistId);
                contentProvider = new FileContentProvider(file);
              }
              openFile(contentProvider, activateEditor: false);
            }
          }
        }
      }
    });
  }

  _EditorState _getStateForUuid(String uuid) {
    for (_EditorState state in _openedEditorStates) {
      if (state.contentProvider.uuid == uuid) {
        return state;
      }
    }

    return null;
  }

  void _switchState(_EditorState state) {
    if (_currentState != state) {
      if (_currentState != null) {
        _currentState.updateState();
      }

      _currentState = state;
      _selectedController.add(currentProvider);
      if (state == null) {
        _aceContainer.switchTo(null);
        persistState();
      } else {
        // Clear text content of ACE editor.
        _aceContainer.switchTo(null);

        if (!state.hasSession) {
          _newFileOpenedController.add(null);
        }

        // Then load content.
        state.withSession().then((state) {
          // Test if other state have been set before this state is appiled.
          if (state != _currentState) {
            return;
          }
          if (editorType(state.contentProvider.name) == EDITOR_TYPE_IMAGE) {
            _selectedController.add(currentProvider);
            persistState();
          } else if (_editorUuidMap[currentProvider.uuid] != null) {
            // TODO: this explicit casting to AceEditor will go away in a
            // future refactoring
            ace.TextEditor textEditor = _editorUuidMap[currentProvider.uuid];
            textEditor.setSession(state.session);
            _selectedController.add(currentProvider);
            _aceContainer.switchTo(state.session, state.contentProvider);
            persistState();
          }
        });
      }
    }
  }

  Timer _timer;

  void _startSaveTimer() {
    if (currentProvider is FileContentProvider) {
      FileContentProvider contentProvider = (currentProvider as FileContentProvider);
      _eventBus.addEvent(new FileModifiedBusEvent(contentProvider.file));
    }

    if (_timer != null) _timer.cancel();
    _timer = new Timer(new Duration(milliseconds: _DELAY_MS), () =>
        _saveAll(userAction: false));
  }

  void _saveAll({bool userAction: false}) {
    if (_timer != null) {
      _timer.cancel();
      _timer = null;
    }

    bool wasDirty = false;

    // TODO: We need to rethink how this is done.  Since this happens after
    // a timer, the state may have changed since the timer started.  This could
    // affect everything that follows (saving, rebuilding, etc) if the editor
    // state changes between the timer start and now.
    for (Editor editor in editors) {
      if (editor.dirty) {
        editor.save();
        wasDirty = true;
      }
    }

    if (wasDirty) {
      if (userAction) {
        _eventBus.addEvent(
            new SimpleBusEvent(BusEventType.EDITOR_MANAGER__FILES_SAVED));
      } else {
        _eventBus.addEvent(
            new SimpleBusEvent(BusEventType.EDITOR_MANAGER__FILES_SAVED_AUTOMATICALLY));
      }
    } else if (userAction) {
      _eventBus.addEvent(
          new SimpleBusEvent(BusEventType.EDITOR_MANAGER__NO_MODIFICATIONS));
    }
  }

  int editorType(String filename) {
    if (isImageFilename(filename)) {
      return EDITOR_TYPE_IMAGE;
    } else {
      return EDITOR_TYPE_TEXT;
    }
  }

  void _handleFileDeleted(Resource file) {
    if (!file.isFile) {
      return;
    }
    // If the file is open in an editor, the editor will take care of closing.
    if (_editorUuidMap.containsKey(file.uuid)) {
      return;
    }

    String key = file.uuid;

    if (_savedEditorStates.containsKey(key)) {
      _savedEditorStates.remove(key);
    }
  }

  void _handleFileChanged(File file) {
    // If the file is open in an editor, the editor will take care of updating.
    if (_editorUuidMap.containsKey(file.uuid)) {
      return;
    }

    String key = file.uuid;

    if (_savedEditorStates.containsKey(key)) {
      // Update the saved state.
      _savedEditorStates[key].handleFileChanged();
    }
  }

  // EditorProvider
  Editor createEditorForContentProvider(ContentProvider contentProvider) {
    Editor editor = _editorUuidMap[contentProvider.uuid];
    assert(editor == null);
    if (editorType(contentProvider.name) == EDITOR_TYPE_IMAGE) {
      // TODO(ericarnold): For now, assuming that all images are files.
      editor = new ImageViewer(contentProvider as FileContentProvider);
    } else {
      editor = new ace.TextEditor(_aceContainer, contentProvider, _prefs);
      editor.resize();
    }

    _editorUuidMap[contentProvider.uuid] = editor;
    openFile(contentProvider);
    editor.onModification.listen((_) => _startSaveTimer());
    return editor;
  }

  void activate(Editor editor) {
    _EditorState state = _getStateForUuid(editor.contentProvider.uuid);
    _switchState(state);
  }

  NavigationLocation get navigationLocation => _aceContainer.navigationLocation;

  void setupOutline(html.Element outlineContainer) {
    _aceContainer.setupOutline(outlineContainer);
  }
}

/**
 * This class tracks the state associated with each open editor.
 *
 * TODO(devoncarew): We want to remove this class and track state in each editor.
 */
class _EditorState {
  EditorManager manager;
  ContentProvider contentProvider;
  ace.EditSession session;

  _EditorState.fromFile(this.manager, File file) {
    contentProvider = new FileContentProvider(file);
  }

  _EditorState.fromContentProvider(this.manager, ContentProvider contentProvider) {
    this.contentProvider = contentProvider;
  }

  factory _EditorState.fromMap(EditorManager manager, Map m) {
    File f = manager._workspace.restoreResource(m['file']);

    if (f == null) {
      return null;
    } else {
      _EditorState state = new _EditorState.fromFile(manager, f);
      return state;
    }
  }

  bool get hasSession => session != null;

  // This method save the ACE editor state in this class. Then, further calls
  // of toMap() to save the state of the editor will return correct values.
  void updateState() { }

  /**
   * Return a [Map] representing the persistable state of this editor. This map
   * can later be passed into [_EditorState.fromMap] to restore the state.
   */
  Map toMap() {
    Map m = {};
    m['file'] = contentProvider.uuid;
    return m;
  }

  Future<_EditorState> withSession() {
    if (hasSession) {
      return new Future.value(this);
    } else {
      if (manager.editorType(contentProvider.name) == EditorManager.EDITOR_TYPE_IMAGE) {
        return new Future.value(this);
      } else {
        return contentProvider.read().then((text) {
          session = manager._aceContainer.createEditSession(text, contentProvider.name);
          return this;
        });
      }
    }
  }

  void handleFileChanged() {
    if (session != null) {
      contentProvider.read().then((String text) {
        session.value = text;
      });
    }
  }

  void close() {
    session = null;
  }
}

/**
 * Defines an abstract provider of data (content) from an unknown source,
 * provides an event to fire upon content changes, and allows the content to be
 * written to / read from source.
 */
abstract class ContentProvider {
  String get name;
  String get uuid;
  Stream get onChange;
  Future write(String content);
  Future<String> read();

  bool operator==(ContentProvider other) {
    if (other is! ContentProvider) return false;
    return uuid == other.uuid;
  }
}

/**
 * Defines a provider of content from a [File].
 */
class FileContentProvider implements ContentProvider {
  final File file;

  String get name => file.name;
  String get uuid => file.uuid;

  StreamController _changeController;
  StreamSubscription _changeSubscription;

  Stream get onChange => _changeController.stream;

  FileContentProvider(this.file) {
    _changeController = new StreamController.broadcast(onListen: () {
      _changeSubscription = file.workspace.onResourceChange.listen(
          (ResourceChangeEvent event) {
            if (event.modifiedFiles.contains(file)) _changeController.add(null);
          });
    }, onCancel: () => _changeSubscription.cancel());
  }

  Future<String> read() => file.getContents();

  Future write(String content) => file.setContents(content);
}

/**
 * Defines a provider of content from an element named [name] in a
 * [PreferenceStore] [_store].
 */
class PreferenceContentProvider implements ContentProvider {
  final PreferenceStore _store;
  final String name;

  StreamController _changeController = new StreamController.broadcast();
  Stream get onChange => _changeController.stream;

  // TODO(ericarnold): Deal with multiple [PreferenceStore]s?
  String get uuid => "PreferenceContentProvider:$name";

  PreferenceContentProvider(this._store, this.name);

  Future<String> read() => _store.getValue(name)
        .then((String content) =>
            content == null ? "" : content);

  Future write(String content) => _store.setValue(name, content);
}

