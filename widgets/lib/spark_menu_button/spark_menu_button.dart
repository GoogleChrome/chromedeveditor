// Copyright (c) 2013, Google Inc. Please see the AUTHORS file for details.
// All rights reserved. Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

library spark_widgets.menu_button;

import 'dart:html';

import 'package:polymer/polymer.dart';

import '../common/spark_widget.dart';
import '../spark_menu/spark_menu.dart';
// TODO(ussuri): Temporary. See the comment below.
import '../spark_overlay/spark_overlay.dart';

@CustomTag("spark-menu-button")
class SparkMenuButton extends SparkWidget {
  @published String src = "";
  @published dynamic selected;
  @published String valueattr = "";
  @published bool opened = false;
  @published bool responsive = false;
  @published String valign = "center";

  SparkOverlay _overlay;
  SparkMenu _menu;

  SparkMenuButton.created(): super.created();

  @override
  void enteredView() {
    super.enteredView();

    _overlay = $['overlay'];
    _menu = $['menu'];
  }

  //* Toggle the opened state of the dropdown.
  void toggle([var event, bool inOpened]) {
    final bool newOpened = inOpened != null ? inOpened : !opened;
    if (newOpened != opened) {
      opened = newOpened;
      // TODO(ussuri): A temporary plug to make spark-overlay see changes
      // in 'opened' when run as deployed code. Just binding via {{opened}}
      // alone isn't detected and the menu doesn't open.
      if (IS_DART2JS) {
        _overlay.opened = opened;
      }
      if (opened) {
        // Enforce focused state so the button can accept keyboard events.
        focus();
        _menu.resetState();
      }
    }
  }

  void open() => toggle(null, true);

  void close() => toggle(null, false);

  //* Handle the on-opened event from the dropdown. It will be fired e.g. when
  //* mouse is clicked outside the dropdown (with autoClosedDisabled == false).
  void onOpened(CustomEvent e) {
    // Autoclosing is the only event we're interested in.
    if (e.detail == false) {
      opened = false;
    }
  }

  void menuActivateHandler(CustomEvent e, var details) {
    if (details['isSelected']) {
      close();
    }
  }

  void keyDownHandler(KeyboardEvent e) {
    bool stopPropagation = true;

    if (_menu.maybeHandleKeyStroke(e.keyCode)) {
      e.preventDefault();
    }

    switch (e.keyCode) {
      case KeyCode.UP:
      case KeyCode.DOWN:
      case KeyCode.PAGE_UP:
      case KeyCode.PAGE_DOWN:
      case KeyCode.ENTER:
        if (!opened) opened = true;
        break;
      case KeyCode.ESC:
        if (opened) opened = false;
        break;
      default:
        stopPropagation = false;
        break;
    }

    if (stopPropagation) {
      e.stopPropagation();
    }
  }
}
