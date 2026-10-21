//go:build !windows

package doctor

func (c *Checker) systemProxyCheck() Check {
	return Check{}
}
