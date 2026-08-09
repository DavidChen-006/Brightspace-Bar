extension Array {
    func repoBarBatches(of size: Int) -> [ArraySlice<Element>] {
        guard size > 0 else { return [self[...]] }

        var result: [ArraySlice<Element>] = []
        var index = self.startIndex
        while index < self.endIndex {
            let nextIndex = self.index(index, offsetBy: size, limitedBy: self.endIndex) ?? self.endIndex
            result.append(self[index ..< nextIndex])
            index = nextIndex
        }
        return result
    }
}
