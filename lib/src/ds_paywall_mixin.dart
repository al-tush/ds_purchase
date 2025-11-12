import 'dart:async';

import 'package:ds_common/core/ds_metrica.dart';
import 'package:ds_purchase/ds_purchase.dart';
import 'package:flutter/material.dart';

mixin DSPaywallMixin<T extends StatefulWidget>
    on State<T>, WidgetsBindingObserver {
  DSPurchaseManager get pm => DSPurchaseManager.I;
  DSPaywall get paywall => pm.paywall!;

  Future<void> Function() get closeCallback;

  var _lastStatAction = 'paywall opened';
  var _lastStatTime = DateTime.timestamp();

  var _subscribingIdx = -1;
  int get subscribingIdx => _subscribingIdx;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    pm.logShowPaywall(paywall);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> closeButtonHandler() async {
    DSMetrica.reportEvent('Paywall: paywall closed', attributes: {
      'paywall_id': pm.placementId,
      'variant_paywall': pm.paywallVariant, // deprecated
      'paywall_name': '${pm.paywall?.name}',
      'paywall_type': pm.paywallType,
      'last_action': _lastStatAction,
      'time_sec': DateTime.timestamp().difference(_lastStatTime).inSeconds,
    });
    await closeCallback();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _lastStatTime = DateTime.timestamp();
        _lastStatAction = 'app resumed';
      case AppLifecycleState.paused:
        DSMetrica.reportEvent('Paywall: app turned off', attributes: {
          'paywall_id': pm.placementId,
          'variant_paywall': pm.paywallVariant, // deprecated
          'paywall_name': '${pm.paywall?.name}',
          'paywall_type': pm.paywallType,
          'last_action': _lastStatAction,
          'time_sec': DateTime.timestamp().difference(_lastStatTime).inSeconds,
        });
        _lastStatTime = DateTime.timestamp();
        _lastStatAction = 'app turned off';
      default:
    }
  }

  Future<bool> buy({
    required DSProduct product,
    required int buttonIdx,
    required Map<String, Object> attributes,
  }) async {
    if (_subscribingIdx >= 0) return false;
    _subscribingIdx = buttonIdx;
    setState(() {});
    try {
      DSMetrica.reportEvent('Paywall: click button', attributes: {
        'paywall_id': pm.placementId,
        'variant_paywall': pm.paywallVariant, // deprecated
        'paywall_name': '${pm.paywall?.name}',
        'paywall_type': pm.paywallType,
        'vendor_product': product.id,
        'vendor_offer_id': product.offerId ?? 'null',
        'product_index': buttonIdx,
        'last_action': _lastStatAction,
        'time_sec': DateTime.timestamp().difference(_lastStatTime).inSeconds,
        ...attributes,
      });
      _lastStatTime = DateTime.timestamp();
      _lastStatAction = 'click to subscribe';
      final res = await pm.buy(product: product);
      if (res) {
        _lastStatTime = DateTime.timestamp();
        _lastStatAction = 'subscribed';
        await closeCallback();
      }
      return res;
    } finally {
      if (mounted) {
        setState(() {
          _subscribingIdx = -1;
        });
      }
    }
  }
}
