use aiken/hash.{Blake2b_224, Hash}
use aiken/transaction/credential.{Address, VerificationKey}

pub type Datum {
  // utxo containing the administrative data such as admin keys
  AdminData {
    admin_keys: List<Hash<Blake2b_224, VerificationKey>>,
    fee: Int,
    fee_address: Address,
    backend_key: Hash<Blake2b_224, VerificationKey>,
  }
  //bank utxos
  Bank
  // utxo containing a user's bet
  Bet { owner: Address, amount: Int }
}

pub type Redeemer {
  // fulfil a bet. Contains the numerator and denominator of the random number generated by the game.
  FulfilBet { rn_numerator: Int, rn_denominator: Int }
  // redeemer to withdraw funds from the bank
  WithdrawBank
  // redeemer to update the admin data.
  UpdateAdminData
}