use aiken/cbor
use aiken/hash.{Blake2b_224, Hash}
use aiken/list
use aiken/math/rational.{Rational}
use aiken/transaction.{
  InlineDatum, Input, Output, OutputReference, ScriptContext, Spend, Transaction,
} as tx
use aiken/transaction/credential.{
  Address, Script, ScriptCredential, VerificationKey,
}
use aiken/transaction/value
use cardanocasino/types

validator(legitimacy_policy: ByteArray, legitimacy_name: ByteArray) {
  fn spend(
    _datum: types.Datum,
    redeemer: types.Redeemer,
    ctx: ScriptContext,
  ) -> Bool {
    let ScriptContext { transaction, purpose } = ctx

    expect Spend(output_ref) = purpose

    let Transaction { inputs, reference_inputs, outputs, .. } = transaction

    let val_hash = own_validator_script_address_hash(inputs, output_ref)

    when redeemer is {
      types.FulfilBet(rn_numerator, rn_denominator) -> {
        expect Some(random_number) = rational.new(rn_numerator, rn_denominator)

        let multiplier = get_multiplier(random_number)

        let script_inputs = get_script_inputs(inputs, val_hash)
        let bet_inputs = get_bet_inputs(script_inputs)
        let only_one_bet = list.length(bet_inputs) == 1

        let only_bet_or_bank =
          list.all(
            script_inputs,
            fn(input) {
              expect InlineDatum(data) = input.output.datum
              expect datum: types.Datum = data
              when datum is {
                types.Bank -> True
                types.Bet(..) -> True
                _ -> False
              }
            },
          )

        let bet_input_option = list.head(bet_inputs)
        expect Some(bet_input) = bet_input_option
        expect InlineDatum(data) = bet_input.output.datum
        expect datum: types.Datum = data
        expect types.Bet(owner, amount) = datum

        let bet_atleast_one_ada = amount > 1_000_000

        let user_amount = amount * multiplier
        let bank_amount = -user_amount

        let amount_sent_to_bet_owner =
          lovelace_sent_to_address(inputs, outputs, owner)
        let correct_amount_sent_to_owner =
          amount_sent_to_bet_owner >= user_amount

        let amount_sent_to_bank =
          lovelace_sent_to_bank(inputs, outputs, val_hash)
        let correct_amount_sent_to_bank = amount_sent_to_bank >= bank_amount
        let no_tokens_sent_to_bank =
          check_tokens_sent_to_bank(outputs, val_hash)

        let admin_datum =
          get_admin_data(
            reference_inputs,
            val_hash,
            legitimacy_policy,
            legitimacy_name,
          )
        expect types.AdminData(_, fee, fee_address, backend_key) = admin_datum

        expect Some(fee_rational) = rational.new(fee, 10000)

        let amount_rational = rational.from_int(amount)

        let fee_amount_rational = rational.mul(fee_rational, amount_rational)
        let actual_fee = rational.ceil(fee_amount_rational)

        let fee_paid =
          lovelace_sent_to_address(inputs, outputs, fee_address) >= actual_fee

        let tx_signed_by_backend =
          list.has(transaction.extra_signatories, backend_key)
        only_bet_or_bank? && only_one_bet? && bet_atleast_one_ada? && correct_amount_sent_to_owner? && correct_amount_sent_to_bank? && no_tokens_sent_to_bank? && tx_signed_by_backend? && fee_paid?
      }
      types.WithdrawBank -> {
        let admin_datum =
          get_admin_data(
            reference_inputs,
            val_hash,
            legitimacy_policy,
            legitimacy_name,
          )
        expect types.AdminData(admin_keys, ..) = admin_datum

        let script_inputs = get_script_inputs(inputs, val_hash)
        let only_bank_inputs =
          list.all(
            script_inputs,
            fn(input) {
              expect InlineDatum(data) = input.output.datum
              expect datum: types.Datum = data
              when datum is {
                types.Bank -> True
                _ -> False
              }
            },
          )

        let quorum_reached = check_quorum(admin_keys, transaction)
        only_bank_inputs && quorum_reached
      }
      types.UpdateAdminData -> {
        let script_inputs = get_script_inputs(inputs, val_hash)

        let only_one_input = list.length(script_inputs) == 1
        let admin_datum =
          get_admin_data(
            script_inputs,
            val_hash,
            legitimacy_policy,
            legitimacy_name,
          )
        expect types.AdminData(admin_keys, ..) = admin_datum
        let quorum_reached = check_quorum(admin_keys, transaction)

        let script_outputs =
          list.filter(
            outputs,
            fn(output) {
              output.address == Address {
                payment_credential: ScriptCredential(val_hash),
                stake_credential: None,
              } && value.quantity_of(
                output.value,
                legitimacy_policy,
                legitimacy_name,
              ) == 1 && value.policies(output.value) == [legitimacy_policy]
            },
          )
        let only_one_script_output = list.length(script_outputs) == 1

        let output_valid =
          list.all(
            script_outputs,
            fn(output) {
              expect InlineDatum(data) = output.datum
              expect datum: types.Datum = data
              when datum is {
                types.AdminData(..) ->
                  value.quantity_of(
                    output.value,
                    legitimacy_policy,
                    legitimacy_name,
                  ) == 1 && value.policies(output.value) == [legitimacy_policy]
                _ -> False
              }
            },
          )

        only_one_input? && quorum_reached? && only_one_script_output? && output_valid?
      }
    }
  }
}

fn own_validator_script_address_hash(
  inputs: List<Input>,
  output_reference: OutputReference,
) -> Hash<Blake2b_224, Script> {
  expect Some(input) =
    list.find(inputs, fn(input) { input.output_reference == output_reference })
  expect ScriptCredential(hash) = input.output.address.payment_credential

  hash
}

fn get_script_inputs(
  inputs: List<Input>,
  val_hash: Hash<Blake2b_224, Script>,
) -> List<Input> {
  let script_inputs =
    list.filter(
      inputs,
      fn(input) {
        input.output.address.payment_credential == ScriptCredential(val_hash)
      },
    )

  script_inputs
}

fn get_bet_inputs(script_inputs: List<Input>) -> List<Input> {
  let bet_inputs =
    list.filter(
      script_inputs,
      fn(input) {
        expect InlineDatum(data) = input.output.datum
        expect datum: types.Datum = data
        when datum is {
          types.Bet(..) -> True
          _ -> False
        }
      },
    )
  bet_inputs
}

fn lovelace_sent_to_address(
  inputs: List<Input>,
  outputs: List<Output>,
  address: Address,
) -> Int {
  let inputs_from_address =
    list.filter(inputs, fn(input) { input.output.address == address })
  let ada_from_address =
    list.foldl(
      inputs_from_address,
      0,
      fn(input, total) { total + value.lovelace_of(input.output.value) },
    )
  let outputs_to_address =
    list.filter(outputs, fn(output) { output.address == address })

  let ada_to_address =
    list.foldl(
      outputs_to_address,
      0,
      fn(output, total) { total + value.lovelace_of(output.value) },
    )

  ada_to_address - ada_from_address
}

fn lovelace_sent_to_bank(
  inputs: List<Input>,
  outputs: List<Output>,
  val_hash: Hash<Blake2b_224, Script>,
) -> Int {
  let inputs_from_bank =
    list.filter(
      inputs,
      fn(input) {
        input.output.address.payment_credential == ScriptCredential(val_hash) && input.output.datum == InlineDatum(
          types.Bank,
        )
      },
    )
  let ada_from_bank =
    list.foldl(
      inputs_from_bank,
      0,
      fn(input, total) { total + value.lovelace_of(input.output.value) },
    )
  let outputs_to_bank =
    list.filter(
      outputs,
      fn(output) {
        output.address.payment_credential == ScriptCredential(val_hash) && output.datum == InlineDatum(
          types.Bank,
        )
      },
    )

  let ada_to_bank =
    list.foldl(
      outputs_to_bank,
      0,
      fn(output, total) { total + value.lovelace_of(output.value) },
    )

  ada_to_bank - ada_from_bank
}

fn check_tokens_sent_to_bank(
  outputs: List<Output>,
  val_hash: Hash<Blake2b_224, Script>,
) {
  let outputs_to_bank =
    list.filter(
      outputs,
      fn(output) {
        output.address.payment_credential == ScriptCredential(val_hash) && output.datum == InlineDatum(
          types.Bank,
        )
      },
    )
  list.all(outputs_to_bank, fn(output) { value.policies(output.value) == [] })
}

fn get_admin_data(
  inputs: List<Input>,
  val_hash: Hash<Blake2b_224, Script>,
  legitimacy_policy: ByteArray,
  legitimacy_name: ByteArray,
) -> types.Datum {
  let admin_data_inputs =
    list.filter(
      inputs,
      fn(input) {
        expect InlineDatum(data) = input.output.datum
        expect datum: types.Datum = data
        when datum is {
          types.AdminData(..) ->
            input.output.address.payment_credential == ScriptCredential(
              val_hash,
            ) && value.quantity_of(
              input.output.value,
              legitimacy_policy,
              legitimacy_name,
            ) == 1
          _ -> False
        }
      },
    )

  if list.length(admin_data_inputs) != 1 {
    trace cbor.diagnostic(list.length(admin_data_inputs))
    fail @"Multiple or no AdminData datums found"
  } else {
    let admin_data_input_option = list.head(admin_data_inputs)
    expect Some(admin_data_input) = admin_data_input_option
    expect InlineDatum(data) = admin_data_input.output.datum
    expect datum: types.Datum = data
    expect types.AdminData(..) = datum

    datum
  }
}

fn check_quorum(
  admin_keys: List<Hash<Blake2b_224, VerificationKey>>,
  transaction: Transaction,
) {
  let quorum_amount = list.length(admin_keys) / 2 + 1
  let signature_amounts =
    list.foldl(
      admin_keys,
      0,
      fn(key, total) {
        if list.has(transaction.extra_signatories, key) {
          total + 1
        } else {
          total
        }
      },
    )
  signature_amounts >= quorum_amount
}

fn get_multiplier(random_number: Rational) {
  let two_lower_1 = rational.zero()
  expect Some(two_upper_1) = rational.new(196793, 12500)
  expect Some(two_lower_2) = rational.new(2186123, 100000)
  expect Some(two_upper_2) = rational.new(594659, 20000)
  expect Some(six_lower_1) = rational.new(196793, 12500)
  expect Some(six_upper_1) = rational.new(1784257, 100000)
  expect Some(six_lower_2) = rational.new(1952887, 100000)
  expect Some(six_upper_2) = rational.new(2186123, 100000)
  expect Some(ten_lower_1) = rational.new(1784257, 100000)
  expect Some(ten_upper_1) = rational.new(225831, 12500)
  expect Some(ten_lower_2) = rational.new(1929097, 100000)
  expect Some(ten_upper_2) = rational.new(1952887, 100000)
  expect Some(sixteen_lower_1) = rational.new(225831, 12500)
  expect Some(sixteen_upper_1) = rational.new(915219, 50000)
  expect Some(twenty_lower_1) = rational.new(915219, 50000)
  expect Some(twenty_upper_1) = rational.new(367347, 20000)
  expect Some(twenty_lower_2) = rational.new(1494111, 50000)
  expect Some(twenty_upper_2) = rational.new(2994519, 100000)
  expect Some(twenty_lower_3) = rational.new(599277, 20000)
  expect Some(twenty_upper_3) = rational.new(1498309, 50000)
  expect Some(eight_lower_1) = rational.new(367347, 20000)
  expect Some(eight_upper_1) = rational.new(1929097, 100000)
  expect Some(fifteen_lower_1) = rational.new(594659, 20000)
  expect Some(fifteen_upper_1) = rational.new(1494111, 50000)
  expect Some(twentyfive_lower_1) = rational.new(2994519, 100000)
  expect Some(twentyfive_upper_1) = rational.new(599277, 20000)

  if
  rational.compare_with(random_number, >=, two_lower_1) && rational.compare_with(
    random_number,
    <=,
    two_upper_1,
  ) || rational.compare_with(random_number, >, two_lower_2) && rational.compare_with(
    random_number,
    <=,
    two_upper_2,
  ){
  
    2
  } else if rational.compare_with(random_number, >, six_lower_1) && rational.compare_with(
    random_number,
    <=,
    six_upper_1,
  ) || rational.compare_with(random_number, >, six_lower_2) && rational.compare_with(
    random_number,
    <=,
    six_upper_2,
  ) {
    6
  } else if rational.compare_with(random_number, >, ten_lower_1) && rational.compare_with(
    random_number,
    <=,
    ten_upper_1,
  ) || rational.compare_with(random_number, >, ten_lower_2) && rational.compare_with(
    random_number,
    <=,
    ten_upper_2,
  ) {
    10
  } else if rational.compare_with(random_number, >, sixteen_lower_1) && rational.compare_with(
    random_number,
    <=,
    sixteen_upper_1,
  ) {
    16
  } else if rational.compare_with(random_number, >, twenty_lower_1) && rational.compare_with(
    random_number,
    <=,
    twenty_upper_1,
  ) || rational.compare_with(random_number, >, twenty_lower_2) && rational.compare_with(
    random_number,
    <=,
    twenty_upper_2,
  ) || rational.compare_with(random_number, >, twenty_lower_3) && rational.compare_with(
    random_number,
    <=,
    twenty_upper_3,
  ) {
    20
  } else if rational.compare_with(random_number, >, eight_lower_1) && rational.compare_with(
    random_number,
    <=,
    eight_upper_1,
  ) {
    8
  } else if rational.compare_with(random_number, >, fifteen_lower_1) && rational.compare_with(
    random_number,
    <=,
    fifteen_upper_1,
  ) {
    15
  } else if rational.compare_with(random_number, >, twentyfive_lower_1) && rational.compare_with(
    random_number,
    <=,
    twentyfive_upper_1,
  ) {
    25
  } else {
    -1
  }
}

test check_multiplier() {
  expect Some(number) = rational.new(300, 10)
  get_multiplier(number) == -1
}