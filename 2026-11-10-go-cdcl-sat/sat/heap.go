package sat

// varHeap is a binary max-heap of variables ordered by VSIDS activity,
// with an index map so a variable's position can be updated in O(log n).
type varHeap struct {
	act  *[]float64
	heap []int
	idx  []int // position in heap, -1 if absent
}

func (h *varHeap) less(a, b int) bool { return (*h.act)[a] > (*h.act)[b] }
func (h *varHeap) empty() bool        { return len(h.heap) == 0 }

func (h *varHeap) contains(v int) bool { return v < len(h.idx) && h.idx[v] >= 0 }

func (h *varHeap) insert(v int) {
	for len(h.idx) <= v {
		h.idx = append(h.idx, -1)
	}
	h.idx[v] = len(h.heap)
	h.heap = append(h.heap, v)
	h.up(h.idx[v])
}

func (h *varHeap) up(i int) {
	v := h.heap[i]
	for i > 0 {
		p := (i - 1) / 2
		if !h.less(v, h.heap[p]) {
			break
		}
		h.heap[i] = h.heap[p]
		h.idx[h.heap[i]] = i
		i = p
	}
	h.heap[i] = v
	h.idx[v] = i
}

func (h *varHeap) down(i int) {
	v := h.heap[i]
	n := len(h.heap)
	for {
		c := 2*i + 1
		if c >= n {
			break
		}
		if c+1 < n && h.less(h.heap[c+1], h.heap[c]) {
			c++
		}
		if !h.less(h.heap[c], v) {
			break
		}
		h.heap[i] = h.heap[c]
		h.idx[h.heap[i]] = i
		i = c
	}
	h.heap[i] = v
	h.idx[v] = i
}

func (h *varHeap) pop() int {
	v := h.heap[0]
	last := h.heap[len(h.heap)-1]
	h.heap = h.heap[:len(h.heap)-1]
	h.idx[v] = -1
	if len(h.heap) > 0 {
		h.heap[0] = last
		h.idx[last] = 0
		h.down(0)
	}
	return v
}
