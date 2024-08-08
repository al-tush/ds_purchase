import 'package:adapty_flutter/adapty_flutter.dart';
import 'package:ds_purchase/src/entities/ds_product_entity.dart';

extension AdaptyProductExt on AdaptyPaywallProduct {
  DSProductEntity toAppProduct() {
    return DSProductEntity(
      id: vendorProductId,
      price: price.amount,
      currencyCode: price.currencyCode,
      currencySymbol: price.currencySymbol,
      localizedPrice: price.localizedString,
      title: localizedTitle,
      description: localizedDescription,
      androidOfferId: subscriptionDetails?.androidOfferId,
      subscriptionPeriod: subscriptionDetails?.subscriptionPeriod.toAppPeriod(),
      localizedSubscriptionPeriod: subscriptionDetails?.localizedSubscriptionPeriod,
    );
  }
}

extension AdaptySubscriptionPeriodExt on AdaptySubscriptionPeriod {
  SubscriptionPeriod toAppPeriod() {
    final unit = switch (this.unit) {
      AdaptyPeriodUnit.day => SubscriptionUnit.day,
      AdaptyPeriodUnit.week => SubscriptionUnit.week,
      AdaptyPeriodUnit.month => SubscriptionUnit.month,
      AdaptyPeriodUnit.year => SubscriptionUnit.year,
      AdaptyPeriodUnit.unknown => SubscriptionUnit.unknown,
    };

    return SubscriptionPeriod(numOfUnits: numberOfUnits, unit: unit);
  }
}
