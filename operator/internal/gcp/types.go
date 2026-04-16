package gcp

// RouterNode is a GCE instance that participates in BGP routing.
type RouterNode struct {
	Name      string
	SelfLink  string
	Zone      string
	IPAddress string
}

// CloudRouterTopology holds discovered Cloud Router interfaces and ASN.
type CloudRouterTopology struct {
	CloudRouterASN int64
	InterfaceNames []string
	InterfaceIPs   []string
}
