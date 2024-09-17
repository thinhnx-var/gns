package registrar

import (
	"std"
	"time"

	"gno.land/p/demo/ufmt"
	// "gno.land/p/demo/mux"
	"gno.land/p/demo/avl"
)

type bidRecord struct {
	DomainName string
	Bidder     std.Address
	HashString string
	Price      int
	StartTime  time.Time
	EndTime    time.Time
	IsOpen     bool
}

var BidRec *avl.Tree // bidRecord -> domainName

// pending logic
func startBiddingSession(domainName string) (result string) {
	ufmt.Println("start bidding session")
	return "ok"
}

// Render() renders welcome message :D
func Render(path string) string {
	return "welcome to varmeta domain name service"
}

/*
	logic should be:
	1. User click register for a dns.
	-> 1.1: dns does not exists -> open bidding session
	-> 1.2: dns existed -> check if open bidding session is openning or not -> if open -> new bidRecord
	2. Bidding session:
	-> 2.1: CommitHash phase: commit hashed string + send joining fee -> creat bidRecord to add to bidRec
	-> 2.2: CommitPrice phase: commit price + secret key: -> if matches -> write price into bidRec ( send the amunt of coin corresponding)
	-> 2.3(?): after CommitPrice phase done, get the winner and register domain for winner by a `Claim` button
	---> admin end bidding auction
	-> 2.3.1: cooldown phase -> waiting for winner -> 2nd winner
	-> 2.4: re-transfer coin from admin to user who not win the bid
the flow is: user want to register new domain name -> start new bidding session -> got the bidding session id
if other want to register to the same domain name -> bidding into this session, if not return to new state
when the session ends, need to have 2nd phase called commit -> commit their price and secret to compute the hash
-> compare the hash as in record -> accept the hash -> accept the price
*/
// temp approach: everytime user commit, user open a bid session if not existed, if existed -> check if this session is ended.

// commit the domain name and computed hash string
func CommitHash(domainName, hashString string) string {
	caller := std.GetOrigCaller()
	now := time.Now()
	endTime := now.Add(defaultExpireTime)

	// update the bid record
	data, existed := BidRec.Get(domainName)

	// if not existed -> create new record
	if !existed {
		bidRec := bidRecord{
			DomainName: domainName,
			Bidder:     caller,
			StartTime:  now,
			EndTime:    endTime,
			IsOpen:     true,
		}
		bidRecList := []bidRecord{bidRec}
		updated := BidRec.Set(domainName, bidRecList)
		if !updated {
			panic("can not updated the record")
		}
	}
	// if existed
	bidRecList := data.([]bidRecord)
	startTime := bidRecList[0].StartTime
	bidRec := bidRecord{
		DomainName: domainName,
		HashString: hashString,
		Bidder: caller,
		StartTime: startTime,
		EndTime: endTime,
		IsOpen: true,
	}
	bidRecList = append(bidRecList, bidRec)
	// Save record
	ok := BidRec.Set(domainName, bidRecList)
	if !ok {
		panic("can not complete bidding")
	}
	return "commit hash done, result recorded"
}

// commit price and secret to reveal auction session
func CommitPrice(price int, secret string, domainName string) bool {
	// compute the hash string, compare to saved hash string in record
	computedHashString := "demo"
	caller := std.GetOrigCaller()
	data, existed := BidRec.Get(domainName)
	if !existed {
		panic("domain name is invalid")
	}
	bidRecList := data.([]bidRecord)
	for _, bidRec := range bidRecList {
		// found it, update the price
		if bidRec.Bidder == caller && bidRec.HashString == computedHashString {
			ok := savePrice(price, domainName, bidRec)
			if !ok {
				panic("can not save price")
			}
			return true
		}
	}
	return false
}

func savePrice(price int, domainName string, rec bidRecord) bool {
	rec.Price = price
	bidRecFinal := []bidRecord{rec}
	ok := BidRec.Set(domainName, bidRecFinal)
	if !ok {
		panic("can not update record")
	}
	return true
}

// find the highest bid in session - incase everyone commited price
func findTheWinner(domainName string) bidRecord {
	winnerBid := bidRecord{}
	data, existed := BidRec.Get(domainName)
	if !existed {
		panic("invalid domain name")
	}
	bidRecList := data.([]bidRecord)
	winnerBid = bidRecList[0]
	for _, bidRec := range bidRecList {
		if bidRec.Price > winnerBid.Price {
			winnerBid = bidRec
		}
	}
	return winnerBid
}

// register the domain for winner
func registerForWinner(domainName string, winnerRec bidRecord) bool {
	winnerAddr := winnerRec.Bidder
	requestInfo := RequestInfo{
		WantedDomain: domainName,
		Caller:       winnerAddr,
		Mode:         "native",
	}
	result := executeRegister(requestInfo)
	if !result.Success {
		panic(result.ResultDetails.Error())
	}
	// register done. Now charge the fee
	feeProcess(requestInfo)
	return false
}


// everyone can call EndBid
// this EndBid checks endTime -> end the auction
func EndBid(domainName string) error {
	now := time.Now()
	data, existed := BidRec.Get(domainName)
	if !existed {
		return ufmt.Errorf("endbid: invalid domain name")
	}
	bidRecList := data.([]bidRecord)
	firstBidRec := bidRecList[0]
	if now.Before(firstBidRec.EndTime) {
		return ufmt.Errorf("endbid: this session can not end before the end time")
	}
	// change all state
	for _, bidRec := range bidRecList {
		bidRec.IsOpen = false
	}
	ok := BidRec.Set(domainName, bidRecList)
	if !ok {
		return ufmt.Errorf("endbid: can not change bid record state")
	}
	return nil
}

// register new domain with bidding process inside - if message is commit hash -> dapp need to call commit hash
func RegisterDomain(domainName string) error {
	reqInfo := RequestInfo{
		WantedDomain: domainName,
		Caller: std.PrevRealm().Addr(),
		Mode: "native",
	}
	result := checkRegisterState(reqInfo)
	// if checkState get the message of which phase this domain name belongs to, then return the status
	if !result.Success && result.Message != "" {
		return ufmt.Errorf(result.Message)
	}
	// concern feeProcess somewhere we need it, for now I put it here to remind
	// fee process as normal - will charge amount of baseFee
	feeProcess(reqInfo)
	return nil
}

func checkRegisterState(req RequestInfo) ExecuteResult {
	// check if domain name is regex valid
	var execRes ExecuteResult
	if !isValidDomain(req.WantedDomain) {
		execRes.Success = false
		execRes.ResultDetails = ErrInvalidDomainName
		return execRes
	}
	// check if dName is registered
	if AlreadyRegistered(req.WantedDomain) {
		execRes.Success = false
		execRes.ResultDetails = ErrAlreadyRegistered
		return execRes
	}
	// changelogs v2: we are using sealed bidding now
	// check if a bidding session is openning -> append new commit hash into record list
	// both existed or not we open new bidding session
	// for now we return a signal for dapps / service to know what to do next
	isOpen, _ := checkBiddingState(req.WantedDomain)
	if isOpen {
		// return signal for dapps
		execRes.Success = false
		execRes.Message = "please commit hash"
		return execRes
	}

	// not found in register repository but also not found in Bidding Record -> panic("error somewhere :D")
	panic(ufmt.Errorf("should not happend"))
	return execRes
}

// open a bidding session
func OpenBiddingSession(domainName string, dur time.Duration) string {
	now := time.Now()
	bidRec := bidRecord{
		DomainName: domainName,
		StartTime:  now,
	}
	bidRecList := []bidRecord{bidRec}
	ok := BidRec.Set(domainName, bidRecList)
	if !ok {
		panic("can not open bidding session")
	}
	return "created bidding session"
}

func checkBiddingState(dName string) (isExisted bool, isOpen bool) {
	data, existed := BidRec.Get(dName)
	if !existed {
		isExisted = false
		isOpen = false
	}
	isExisted = true
	recList := data.([]bidRecord)
	if recList[0].IsOpen {
		isOpen = true
	} else {
		isOpen = false
	}
	return isExisted, isOpen
}