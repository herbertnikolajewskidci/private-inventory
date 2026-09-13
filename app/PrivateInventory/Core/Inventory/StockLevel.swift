struct StockLevel {
    var quantity: Int = 0

    mutating func scanIn() {
        quantity += 1
    }
}
