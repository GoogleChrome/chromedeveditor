// Copyright (c) 2013, Google Inc. Please see the AUTHORS file for details.
// All rights reserved. Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

library test.spark_button;

import 'dart:async' as async;
import 'dart:html' as dom;

import 'package:polymer/polymer.dart';
import 'package:unittest/unittest.dart';
import 'package:unittest/html_enhanced_config.dart';

import 'package:spark_widgets/spark_button/spark_button.dart';
import 'package:spark_widgets/common/spark_widget.dart';

void main() {
  useHtmlEnhancedConfiguration();

  initPolymer().run(() {
    Polymer.onReady.then((e) {

      group('spark-button', () {
        test('default click', () {
          var btn = (dom.document.querySelector('#default') as SparkButton);
          expect(btn, isNotNull);

          async.StreamSubscription clickSubsrc;

          var clicked = expectAsync((dom.Event event) {
            expect(event.target, equals(btn));
            clickSubsrc.cancel();
          });
          clickSubsrc = btn.onClick.listen(clicked);
          btn.click();
        });

        test('attributes', () {
          var btn = (dom.document.querySelector('#default') as SparkButton);
          expect(btn, isNotNull);

          btn.attributes['primary'] = 'true';
          btn.attributes['active'] = 'true';
          btn.attributes['large'] = 'true';
          btn.attributes['small'] = 'false';
          btn.attributes['noPadding'] = 'true';

          var done = expectAsync((){});

          new async.Future.delayed(new Duration(milliseconds: 50),() {
            expect(btn.btnClasses[SparkButton.CSS_PRIMARY], isTrue);
            expect(btn.btnClasses[SparkButton.CSS_DEFAULT], isFalse);
            expect(btn.btnClasses[SparkWidget.CSS_ENABLED], isTrue);
            expect(btn.btnClasses[SparkWidget.CSS_DISABLED], isFalse);
            expect(btn.btnClasses[SparkButton.CSS_LARGE], isTrue);
            expect(btn.btnClasses[SparkButton.CSS_SMALL], isFalse);
            expect(btn.noPadding, isTrue);
            expect(btn.shadowRoot.querySelector('#button').getComputedStyle().padding, equals('0px'));
            expect(btn.attributes['action-id'], isNull);

            btn.attributes['primary'] = 'false';
            btn.attributes['active'] = 'false';
            btn.attributes['large'] = 'false';
            btn.attributes['small'] = 'true';
            btn.attributes['noPadding'] = 'false';
            btn.attributes['action-id'] = 'someAction';


            new async.Future.delayed(new Duration(milliseconds: 550), () {
              expect(btn.btnClasses[SparkButton.CSS_PRIMARY], isFalse);
              expect(btn.btnClasses[SparkButton.CSS_DEFAULT], isTrue);
              expect(btn.btnClasses[SparkWidget.CSS_ENABLED], isFalse);
              expect(btn.btnClasses[SparkWidget.CSS_DISABLED], isTrue);
              expect(btn.btnClasses[SparkButton.CSS_LARGE], isFalse);
              expect(btn.btnClasses[SparkButton.CSS_SMALL], isTrue);
              expect(btn.noPadding, isFalse);
              expect(btn.shadowRoot.querySelector('#button').getComputedStyle().padding, isNot(equals('10px')));
              expect(btn.attributes['action-id'], equals('someAction'));
              done();
            });
          });
        });
      });
    });
  });
}
