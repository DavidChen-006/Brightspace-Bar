extension Array {
    func chunked(into size: Int) -> [ArraySlice<Element>] {
        guard size > 0 else { return [self[...]] }
        var result: [ArraySlice<Element>] = []
        var index = startIndex
        while index < endIndex {
            let nextIndex = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(self[index ..< nextIndex])
            index = nextIndex
        }
        return result
    }
}
