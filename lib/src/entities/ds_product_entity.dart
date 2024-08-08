enum SubscriptionUnit { month, year, week, day, unknown }

class DSProductEntity {
  DSProductEntity({
    required this.id,
    required this.price,
    required this.title,
    this.currencyCode,
    this.subscriptionPeriod,
    this.description,
    this.currencySymbol,
    this.androidOfferId,
    this.localizedSubscriptionPeriod,
    this.localizedPrice,
  });

  final String id;
  final double price;
  final String title;
  final SubscriptionPeriod? subscriptionPeriod;
  final String? description;
  final String? currencyCode;
  final String? currencySymbol;
  final String? androidOfferId;
  final String? localizedSubscriptionPeriod;
  final String? localizedPrice;

  String get formattedPrice => price.toStringAsFixed(2);

  String replaceTags(String text) {
    final priceSymbol = currencySymbol ?? currencyCode ?? '';
    final priceValue = price;
    final locPrice = localizedPrice ?? '$priceValue $priceSymbol';

    text = text.replaceAll('{price}', locPrice);

    var pricePerDay =
        (subscriptionPeriod != null ? priceValue / subscriptionPeriod!.daysInPeriod : priceValue).toStringAsFixed(1);

    text = text.replaceAll('{price_per_day}', '$priceSymbol$pricePerDay');

    final pricePerWeek =
        (subscriptionPeriod != null ? priceValue / subscriptionPeriod!.weeksInPeriod : priceValue).toStringAsFixed(1);

    text = text.replaceAll('{price_per_week}', '$priceSymbol$pricePerWeek');

    text = text.replaceAll('{currency}', priceSymbol);

    text = text.replaceAll('{zero_price}', locPrice.replaceAll(RegExp(r'[\d,\.]+'), '0'));

    if (subscriptionPeriod?.daysInPeriod != null) {
      text = text.replaceAll('{days}', subscriptionPeriod!.daysInPeriod.toString());
    }
    
    text = text.replaceAll('{subscription_period}', '$localizedSubscriptionPeriod');

    return text;
  }
}

class SubscriptionPeriod {
  final int numOfUnits;
  final SubscriptionUnit unit;

  SubscriptionPeriod({required this.numOfUnits, required this.unit});

  int get daysInPeriod => switch (unit) {
        SubscriptionUnit.month => 30 * numOfUnits,
        SubscriptionUnit.year => 365 * numOfUnits,
        SubscriptionUnit.week => 7 * numOfUnits,
        SubscriptionUnit.day => numOfUnits,
        SubscriptionUnit.unknown => numOfUnits,
      };

  int get weeksInPeriod => switch (unit) {
        SubscriptionUnit.month => 4 * numOfUnits,
        SubscriptionUnit.year => 52 * numOfUnits,
        SubscriptionUnit.week => numOfUnits,
        SubscriptionUnit.day => (0.14 * numOfUnits).round(),
        SubscriptionUnit.unknown => numOfUnits,
      };
}
