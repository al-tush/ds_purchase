import 'package:adapty_flutter/adapty_flutter.dart';
import 'package:ds_common/core/ds_primitives.dart';
import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:in_app_purchase_storekit/in_app_purchase_storekit.dart';
import 'package:in_app_purchase_storekit/store_kit_2_wrappers.dart';
import 'package:in_app_purchase_storekit/store_kit_wrappers.dart';

@Deprecated('Use DSProduct and its inherited classes')
typedef DSProductEntity = DSProduct;

@Deprecated('Use DSPaywall and its inherited classes')
typedef DSPaywallEntity = DSPaywall;

typedef DSPaywallPlacementTranslator = String Function(
    DSPaywallPlacement paywallType);

@immutable
class DSPaywallPlacement {
  final String val;

  const DSPaywallPlacement(this.val);

  @override
  int get hashCode => val.hashCode;

  @override
  bool operator ==(other) => other is DSPaywallPlacement && val == other.val;

  @override
  String toString() => val;
}

enum DSProviderMode {
  adaptyOnly,
  adaptyFirst,
  nativeFirst,
}

sealed class DSProduct {
  String get id;
  String get providerName;
  double get price;
  String? get currencyCode;
  String? get currencySymbol;
  String get currencySymbolExt {
    if ((currencySymbol ?? '').isNotEmpty) {
      return currencySymbol!;
    }

    // https://www.xe.com/symbols/
    if (currencyCode == 'USD') {
      return 'US\$';
    } else if (currencyCode == 'EUR') {
      return '€';
    } else if (currencyCode == 'GBP') {
      return '£';
    } else if (currencyCode == 'RUB') {
      return '₽';
    }

    return currencyCode ?? '';
  }

  DSSubscriptionPeriod? get subscriptionPeriod;
  DSSubscriptionPeriod? get trialPeriod;
  String? get offerId;
  String? get localizedSubscriptionPeriod;
  String? get localizedPrice;

  late final String formattedPrice = price.toStringAsFixed(2);

  bool get isTrial;

  String replaceTags(String text) {
    final priceSymbol = currencySymbolExt;
    final locPrice = localizedPrice ?? '$price $priceSymbol';

    text = text.replaceAll('{price}', locPrice);

    var pricePerDay = (subscriptionPeriod != null
        ? price / subscriptionPeriod!.daysInPeriod
        : price)
        .toStringAsFixed(1);

    text = text.replaceAll('{price_per_day}', '$priceSymbol$pricePerDay');

    final pricePerWeek = (subscriptionPeriod != null
        ? price / subscriptionPeriod!.weeksInPeriod
        : price)
        .toStringAsFixed(1);

    text = text.replaceAll('{price_per_week}', '$priceSymbol$pricePerWeek');

    text = text.replaceAll('{currency}', priceSymbol);

    text = text.replaceAll(
        '{zero_price}', locPrice.replaceAll(RegExp(r'[\d,.]+'), '0'));

    if (subscriptionPeriod?.daysInPeriod != null) {
      text = text.replaceAll(
          '{days}', subscriptionPeriod!.daysInPeriod.toString());
    }

    text = text.replaceAll(
        '{subscription_period}', '$localizedSubscriptionPeriod');

    return text;
  }
}

sealed class DSPaywall {
  String get name;
  String get providerName;
  String get placementId;
  Map<String, dynamic> get remoteConfig;
  List<DSProduct> get products;
}

class DSAdaptyPaywall extends DSPaywall {
  @override
  String get providerName => 'adapty';
  final AdaptyPaywall data;
  final List<DSAdaptyProduct> adaptyProducts;

  DSAdaptyPaywall({
    required this.data,
    required this.adaptyProducts,
  });

  @override
  String get placementId => data.placementId;
  @override
  String get name => data.name;
  @override
  Map<String, dynamic> get remoteConfig => data.remoteConfig?.dictionary ?? const {};
  @override
  List<DSProduct> get products => adaptyProducts.cast<DSProduct>();

  String get paywallType => '${remoteConfig['type'] ?? 'not_defined'}';
  String get paywallVariant => '${remoteConfig['variant_paywall'] ?? 'default'}';

  bool get hasPaywallBuilder => data.hasViewConfiguration;
}

class DSInAppPaywall extends DSPaywall {
  @override
  String get providerName => 'native';
  @override
  String get name => 'native';
  @override
  String placementId;
  @override
  Map<String, dynamic> remoteConfig;
  final List<DSInAppProduct> inAppProducts;

  DSInAppPaywall({
    required this.placementId,
    required this.remoteConfig,
    required this.inAppProducts,
  });

  @override
  List<DSProduct> get products => inAppProducts.cast<DSProduct>();

  String get paywallType => '${remoteConfig['type'] ?? 'not_defined'}';
  String get paywallVariant => '${remoteConfig['variant_paywall'] ?? 'default'}';
}

class DSAdaptyProduct extends DSProduct {
  DSAdaptyProduct({
    required this.data,
  });

  final AdaptyPaywallProduct data;
  @override
  String get id => data.vendorProductId;
  @override
  String get providerName => 'adapty';
  @override
  double get price => data.price.amount;
  @override
  String? get currencyCode => data.price.currencyCode;
  @override
  String? get currencySymbol => data.price.currencySymbol;
  @override
  late final DSSubscriptionPeriod? subscriptionPeriod = data.subscription?.period.let((v) => DSSubscriptionPeriod.fromAdapty(v));
  @override
  // ToDo: TBD
  late final DSSubscriptionPeriod?  trialPeriod = isTrial ? data.subscription?.offer?.phases.first.subscriptionPeriod.let((v) => DSSubscriptionPeriod.fromAdapty(v)) : null;
  @override
  String? get offerId => data.subscription?.offer?.identifier.id;
  @override
  String? get localizedSubscriptionPeriod => data.subscription?.localizedPeriod;
  @override
  String? get localizedPrice => data.price.localizedString;

  @override
  bool get isTrial => data.subscription?.offer?.identifier.type == AdaptySubscriptionOfferType.introductory;
}

sealed class DSInAppProduct extends DSProduct {
  ProductDetails get data;

  @override
  String get id => data.id;

  @override
  String get providerName => 'native';

  @override
  double get price => data.rawPrice;

  @override
  String? get currencyCode => data.currencyCode;

  @override
  DSSubscriptionPeriod? get trialPeriod => throw Exception('TBD');
}

class DSInAppGoogleProduct extends DSInAppProduct {
  DSInAppGoogleProduct({
    required this.googleData,
    required this.offerId,
  }) {
    if (offerId == null && (googleData.productDetails.subscriptionOfferDetails?.length ?? 0) > 1) {
      throw Exception('offer_id does not identify the subscription uniquely');
    }
    if (offerId != null && googleData.productDetails.subscriptionOfferDetails?.any((e) => e.offerId == offerId) != true) {
      throw Exception('passed offer_id does not exist');
    }
  }

  @override
  ProductDetails get data => googleData;

  final GooglePlayProductDetails googleData;

  SubscriptionOfferDetailsWrapper? get offer {
    if (offerId == null) {
      // use subscriptionIndex???
      return googleData.productDetails.subscriptionOfferDetails?.firstOrNull;
    }
    return googleData.productDetails.subscriptionOfferDetails!.firstWhere((e) => e.offerId == offerId);
  }

  @override
  late final DSSubscriptionPeriod? subscriptionPeriod = offer?.let((v) => DSSubscriptionPeriod.fromInAppGoogle(v.pricingPhases));

  @override
  String? offerId;
  @override
  String? get localizedSubscriptionPeriod => '???';
  @override
  String? get localizedPrice => offer!.pricingPhases.last.formattedPrice;
  @override
  String? get currencySymbol => null;

  @override
  bool get isTrial => offer!.pricingPhases.any((t) => t.priceAmountMicros == 0);
}

class DSInAppAppleProduct extends DSInAppProduct {
  DSInAppAppleProduct({
    required this.appleData,
  });

  @override
  ProductDetails get data => appleData;

  final AppStoreProductDetails appleData;

  @override
  late final DSSubscriptionPeriod? subscriptionPeriod = appleData.skProduct.subscriptionPeriod?.let((v) => DSSubscriptionPeriod.fromInAppApple(v));
  @override
  String? offerId;
  @override
  String? get localizedSubscriptionPeriod => '???';
  @override
  String? get localizedPrice => appleData.price;
  @override
  String? get currencySymbol => appleData.currencySymbol;

  @override
  bool get isTrial => id.contains('free');
}

class DSInAppApple2Product extends DSInAppProduct {
  DSInAppApple2Product({
    required this.appleData,
    required this.offerId,
  }) {
    if (offerId == null && (appleData.sk2Product.subscription?.promotionalOffers.length ?? 0) > 1) {
      throw Exception('offer_id does not identify the subscription uniquely');
    }
    if (offerId != null && appleData.sk2Product.subscription?.promotionalOffers.any((e) => e.id == offerId) != true) {
      throw Exception('passed offer_id does not exist');
    }
  }

  @override
  ProductDetails get data => appleData;

  final AppStoreProduct2Details appleData;

  SK2SubscriptionOffer? get offer {
    if (offerId == null) {
      // use subscriptionIndex???
      return appleData.sk2Product.subscription?.promotionalOffers.firstOrNull;
    }
    return appleData.sk2Product.subscription?.promotionalOffers.firstWhere((e) => e.id == offerId);
  }

  @override
  late final DSSubscriptionPeriod? subscriptionPeriod = appleData.sk2Product.subscription?.let((v) => DSSubscriptionPeriod.fromInAppApple2(v.subscriptionPeriod));
  @override
  String? offerId;
  @override
  String? get localizedSubscriptionPeriod => '???';
  @override
  String? get localizedPrice => appleData.price;
  @override
  String? get currencySymbol => appleData.currencySymbol;

  @override
  bool get isTrial => id.contains('free');
}

enum DSSubscriptionUnit { month, year, week, day, unknown }

class DSSubscriptionPeriod {
  final int numOfUnits;
  final DSSubscriptionUnit unit;

  DSSubscriptionPeriod({required this.numOfUnits, required this.unit});

  factory DSSubscriptionPeriod.fromAdapty(AdaptySubscriptionPeriod data) {
    return DSSubscriptionPeriod(
      numOfUnits: data.numberOfUnits,
      unit: switch (data.unit) {
        AdaptyPeriodUnit.day => DSSubscriptionUnit.day,
        AdaptyPeriodUnit.week => DSSubscriptionUnit.week,
        AdaptyPeriodUnit.month => DSSubscriptionUnit.month,
        AdaptyPeriodUnit.year => DSSubscriptionUnit.year,
        AdaptyPeriodUnit.unknown => DSSubscriptionUnit.unknown,
      },
    );
  }

  factory DSSubscriptionPeriod.fromInAppGoogle(List<PricingPhaseWrapper> pricingPhases) {
    // ToDo: TBD
    final data = pricingPhases.last;
    return DSSubscriptionPeriod(
      numOfUnits: data.billingCycleCount,
      unit: DSSubscriptionUnit.day,
    );
  }

  factory DSSubscriptionPeriod.fromInAppApple(SKProductSubscriptionPeriodWrapper period) {
    return DSSubscriptionPeriod(
      numOfUnits: period.numberOfUnits,
      unit: switch (period.unit) {
        SKSubscriptionPeriodUnit.day => DSSubscriptionUnit.day,
        SKSubscriptionPeriodUnit.week => DSSubscriptionUnit.week,
        SKSubscriptionPeriodUnit.month => DSSubscriptionUnit.month,
        SKSubscriptionPeriodUnit.year => DSSubscriptionUnit.year,
      },
    );
  }

  factory DSSubscriptionPeriod.fromInAppApple2(SK2SubscriptionPeriod period) {
    return DSSubscriptionPeriod(
      numOfUnits: period.value,
      unit: switch (period.unit) {
        SK2SubscriptionPeriodUnit.day => DSSubscriptionUnit.day,
        SK2SubscriptionPeriodUnit.week => DSSubscriptionUnit.week,
        SK2SubscriptionPeriodUnit.month => DSSubscriptionUnit.month,
        SK2SubscriptionPeriodUnit.year => DSSubscriptionUnit.year,
      },
    );
  }

  int get daysInPeriod => switch (unit) {
    DSSubscriptionUnit.month => 30 * numOfUnits,
    DSSubscriptionUnit.year => 365 * numOfUnits,
    DSSubscriptionUnit.week => 7 * numOfUnits,
    DSSubscriptionUnit.day => numOfUnits,
    DSSubscriptionUnit.unknown => numOfUnits,
  };

  int get weeksInPeriod => switch (unit) {
    DSSubscriptionUnit.month => 4 * numOfUnits,
    DSSubscriptionUnit.year => 52 * numOfUnits,
    DSSubscriptionUnit.week => numOfUnits,
    DSSubscriptionUnit.day => (0.14 * numOfUnits).round(),
    DSSubscriptionUnit.unknown => numOfUnits,
  };
}
