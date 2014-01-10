// Copyright (c) 2013, Google Inc. Please see the AUTHORS file for details.
// All rights reserved. Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

library spark_widgets.menu_button;

import 'package:polymer/polymer.dart';

import '../common/widget.dart';
import '../spark_menu/spark_menu.dart';

// Ported from Polymer Javascript to Dart code.

@CustomTag("spark-menu-button")
class SparkMenuButton extends Widget {
  @published String src = "";
  @published dynamic selected;
  @published String valueattr = "";
  @published bool opened = false;
  @published bool responsive = false;
  @published String valign = "center";
  @published String selectedClass = "";

  SparkMenuButton.created(): super.created();

  //* Toggle the opened state of the dropdown.
  void toggle() {
    SparkMenu menu = $['overlayMenu'];
    menu.clearSelection();
    opened = !opened;
  }

  //* Returns the selected item.
  String get selection {
    var menu = $['overlayMenu'];
    assert(menu != null);
    return menu.selection;
  }
}
