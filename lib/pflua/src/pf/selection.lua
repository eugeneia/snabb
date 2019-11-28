-- This module implements an "instruction selection" pass over the
-- SSA IR and produces pseudo-instructions for register allocation
-- and code generation.
--
-- This uses a greed matching algorithm over the tree.
--
-- This generates an array of pseudo-instructions like this:
--
--   { { "load", "r1", 12, 2 } }
--     { "add", "r1", "r3" } }
--
-- The instructions available are:
--   * cmp
--   * mov
--   * mov64
--   * load
--   * add
--   * add-i
--   * sub
--   * sub-i
--   * mul
--   * mul-i
--   * div
--   * and
--   * and-i
--   * or
--   * or-i
--   * xor
--   * xor-i
--   * shl
--   * shl-i
--   * shr
--   * shr-i
--   * ntohs
--   * ntohl
--   * uint32
--   * cjmp
--   * jmp
--   * ret
--   * nop (inserted by register allocation)

module(...,package.seeall)

local utils = require("pf.utils")

local verbose = os.getenv("PF_VERBOSE");

local negate_op = { ["="] = "!=", ["!="] = "=",
                    [">"] = "<=", ["<"] = ">=",
                    [">="] = "<", ["<="] = ">" }

-- this maps numeric operations that we handle in a generic way
-- because the instruction selection is very similar
local numop_map = { ["+"] = "add", ["-"] = "sub", ["*"] = "mul",
                    ["*64"] = "mul", ["&"] = "and", ["|"] = "or",
                    ["^"] = "xor" }

-- extract a number from an SSA IR label
function label_num(label)
   return tonumber(string.match(label, "L(%d+)"))
end

-- Convert a block to a sequence of pseudo-instructions
--
-- Virtual registers are given names prefixed with "r" as in "r1".
-- SSA variables remain prefixed with "v"
local function select_block(block, new_register, instructions, next_label, jmp_map)
   local this_label = block.label
   local control    = block.control
   local bindings   = block.bindings

   local function emit(instr)
      table.insert(instructions, instr)
   end

   -- emit a jmp, looking up the next block and replace the jump target if
   -- the next block would immediately jmp anyway (via a return statement)
   local function emit_jmp(target_label, condition)

      -- if the target label is one that was deleted by the return processing
      -- pass, then patch the jump up as appropriate
      local jmp_entry = jmp_map[target_label]
      if jmp_entry then
         if condition then
            emit({ "cjmp", condition, jmp_entry })
         else
            emit({ "jmp", jmp_entry })
         end
         return
      end

      if condition then
         emit({ "cjmp", condition, label_num(target_label) })
      else
         emit({ "jmp", label_num(target_label) })
      end
   end

   local function emit_cjmp(condition, target_label)
      emit_jmp(target_label, condition)
   end

   local function emit_label()
      local max = instructions.max_label
      local num = label_num(this_label)

      if num > max then
         instructions.max_label = num
      end

      emit({ "label", num })
   end

   -- do instruction selection on an arithmetic expression
   -- returns the destination register or immediate
   local function select_arith(expr)
      if type(expr) == "number" then
         if expr > (2 ^ 31)  - 1 then
            tmp = new_register()
            emit({ "mov64", tmp, expr})
            return tmp
         else
            return expr
         end

      elseif type(expr) == "string" then
         return expr

      elseif expr[1] == "[]" then
         local reg = new_register()
         local reg2 = select_arith(expr[2])
         emit({ "load", reg, reg2, expr[3] })
         return reg

      elseif numop_map[expr[1]] then
         local reg2 = select_arith(expr[2])
         local reg3 = select_arith(expr[3])
         local op   = numop_map[expr[1]]
         local op_i = string.format("%s-i", op)

         -- both arguments in registers
         if type(reg2) ~= "number" and type(reg3) ~= "number" then
            local tmp = new_register()
            emit({ "mov", tmp, reg2 })
            emit({ op, tmp, reg3 })
            return tmp

         -- cases with one or more immediate arguments
         elseif type(reg2) == "number" then
            local tmp3 = new_register()
            -- if op is commutative, we can re-arrange to save registers
            if op ~= "sub" then
               emit({ "mov", tmp3, reg3 })
               emit({ op_i, tmp3, reg2 })
               return tmp3
            else
               local tmp2 = new_register()
               emit({ "mov", tmp2, reg2 })
               emit({ "mov", tmp3, reg3 })
               emit({ op, tmp2, tmp3 })
               return tmp2
            end
         elseif type(reg3) == "number" then
            local tmp = new_register()
            emit({ "mov", tmp, reg2 })
            emit({ op_i, tmp, reg3 })
            return tmp
         end

      elseif expr[1] == "/" then
         local reg2 = select_arith(expr[2])
         local rhs = expr[3]
         local tmp = new_register()

         if type(rhs) == "number" then
            -- if dividing by a power of 2, do a shift
            if rhs ~= 0 and bit.band(rhs, rhs-1) == 0 then
               local imm = 0
               rhs = bit.rshift(rhs, 1)
               while rhs ~= 0 do
                  rhs = bit.rshift(rhs, 1)
                  imm = imm + 1
               end

               emit({ "mov", tmp, reg2 })
               emit({ "shr-i", tmp, imm })
            else
               local tmp3 = new_register()
               local reg3 = select_arith(expr[3])
               emit({ "mov", tmp, reg2 })
               emit({ "mov", tmp3, reg3 })
               emit({ "div", tmp, tmp3 })
            end
         else
            local reg3 = select_arith(expr[3])
            emit({ "mov", tmp, reg2 })
            emit({ "div", tmp, reg3 })
         end

         return tmp

      elseif expr[1] == "<<" then
         -- with immediate
         if type(expr[2]) == "number" then
            local reg3 = select_arith(expr[3])
            local tmp = new_register()
            local tmp2 = new_register()
            emit({ "mov", tmp, reg3 })
            emit({ "mov", tmp2, expr[2] })
            emit({ "shl", tmp, tmp2 })
            return tmp
         elseif type(expr[3]) == "number" then
            local reg2 = select_arith(expr[2])
            local imm = expr[3]
            local tmp = new_register()
            emit({ "mov", tmp, reg2 })
            emit({ "shl-i", tmp, imm })
            return tmp

         else
            local reg2 = select_arith(expr[2])
            local reg3 = select_arith(expr[3])
            local tmp1 = new_register()
            local tmp2 = new_register()
            emit({ "mov", tmp1, reg2 })
            emit({ "mov", tmp2, reg3 })
            emit({ "shl", tmp1, tmp2 })
            return tmp1
         end

      elseif expr[1] == ">>" then
         -- with immediate
         if type(expr[2]) == "number" then
            local reg3 = select_arith(expr[3])
            local tmp = new_register()
            local tmp2 = new_register()
            emit({ "mov", tmp, reg3 })
            emit({ "mov", tmp2, expr[2] })
            emit({ "shr", tmp, tmp2 })
            return tmp
         elseif type(expr[3]) == "number" then
            local reg2 = select_arith(expr[2])
            local imm = expr[3]
            local tmp = new_register()
            emit({ "mov", tmp, reg2 })
            emit({ "shr-i", tmp, imm })
            return tmp

         else
            local reg2 = select_arith(expr[2])
            local reg3 = select_arith(expr[3])
            local tmp1 = new_register()
            local tmp2 = new_register()
            emit({ "mov", tmp1, reg2 })
            emit({ "mov", tmp2, reg3 })
            emit({ "shr", tmp1, tmp2 })
            return tmp1
         end

      elseif expr[1] == "ntohs" then
         local reg = select_arith(expr[2])
         local tmp = new_register()
         emit({ "mov", tmp, reg })
         emit({ "ntohs", tmp })
         return tmp

      elseif expr[1] == "ntohl" then
         local reg = select_arith(expr[2])
         local tmp = new_register()
         emit({ "mov", tmp, reg })
         emit({ "ntohl", tmp })
         return tmp

      elseif expr[1] == "uint32" then
         local reg = select_arith(expr[2])
         local tmp = new_register()
         emit({ "mov", tmp, reg })
         emit({ "uint32", tmp })
         return tmp

      else
	 error(string.format("NYI op %s", expr[1]))
      end
   end

   local function select_bool(expr)
      local reg1 = select_arith(expr[2])
      local reg2 = select_arith(expr[3])

      -- cmp can't have an immediate on the lhs, but sometimes unoptimized
      -- pf expressions will have such a comparison which requires an extra
      -- mov instruction
      if type(reg1) == "number" then
         local tmp = new_register()
         emit({ "mov", tmp, reg1 })
         reg1 = tmp
      end

      emit({ "cmp", reg1, reg2 })
   end

   local function select_bindings()
     for _, binding in ipairs(bindings) do
        local rhs = binding.value
        local reg = select_arith(rhs)
        emit({ "mov", binding.name, reg })
     end
   end

   if control[1] == "return" then
      local result = control[2]

      -- Drop blocks are dropped whose returns can just be replaced by directly
      -- jumping to the return labels at the end
      if result[1] ~= "false" and
         result[1] ~= "true" and
         result[1] ~= "call"
      then
         emit_label()
         select_bindings()
         select_bool(result)
         emit({ "cjmp", result[1], "true-label" })
         emit({ "jmp", "false-label" })
      end

   elseif control[1] == "if" then
      local cond = control[2]
      local then_label = control[3]
      local else_label = control[4]

      emit_label()
      select_bindings()
      select_bool(cond)

      if next_label == then_label then
         emit_cjmp(negate_op[cond[1]], else_label)
         emit_jmp(then_label)
      else
         emit_cjmp(cond[1], then_label)
         emit_jmp(else_label)
      end

   elseif control[1] == "call" then
      local call = control[2]
      emit_jmp(call[1])

   else
      error(string.format("NYI op %s", control[1]))
   end
end

local function make_new_register(reg_num)
   return
      function()
         local new_var = string.format("r%d", reg_num)
         reg_num = reg_num + 1
         return new_var
      end
end

-- printing instruction IR for debugging
function print_selection(ir)
   utils.pp({ "instructions", ir })
end

-- removes blocks that just return constant values and return a new
-- SSA order (with returns removed), a map for redirecting jmps, and a map of
-- the required return labels
local function process_returns(ssa)
   -- these control whether to emit pseudo-instructions for return values
   -- ('return true' or 'return false' or 'call ...') at the very end.
   -- (since they may not be needed if the result is always true or false)
   local return_labels = {}
   local return_map = {}

   -- clone to ease testing without side effects
   local order  = utils.dup(ssa.order)
   local blocks = ssa.blocks
   local len    = #order

   -- proceed in reverse order to allow easy deletion
   for i=1, len do
      local idx     = len - i + 1
      local label   = order[idx]
      local block   = blocks[label]
      local control = block.control

      if control[1] == "return" then
         if control[2][1] == "true" then
            return_labels["true-label"] = 1
            return_map[label] = "true-label"
            table.remove(order, idx)
         elseif control[2][1] == "false" then
            return_labels["false-label"] = 0
            return_map[label] = "false-label"
            table.remove(order, idx)
         elseif control[2][1] == "call" then
            local _, target, value = unpack(control[2])
            value = math.ceil(assert(tonumber(value or 0), "Argument 1 must be a number."))
            if return_labels[target] then
               assert(value == return_labels[target], "Conflicting values for: "..target)
            end
            return_labels[target] = value
            return_map[label] = target
            table.remove(order, idx)
         else
            -- a return block with a non-trivial expression requires both
            -- true and false return labels
            return_labels["true-label"] = 1
            return_labels["false-label"] = 0
         end
      end
   end

   return order, return_map, return_labels
end

function select(ssa)
   local blocks = ssa.blocks
   local instructions = { max_label = 0 }

   local reg_num = 1
   local new_register = make_new_register(reg_num)

   local order, jmp_map, returns = process_returns(ssa)

   for idx, label in pairs(order) do
      local next_label = order[idx+1]
      select_block(blocks[label], new_register, instructions,
                   next_label, jmp_map)
   end

   -- append return pseudo-instructions, and try to order them so that the last
   -- jmp (if any) targets the first ret target (so that codegen can detect a
   -- fall-through and omit the jump); alternatively sort them by their value.
   local return_order = {}
   for label, value in pairs(returns) do
      table.insert(return_order, {label=label, value=value})
   end
   local last_instr = instructions[#instructions]
   local default_return
   if last_instr and last_instr[1] == "jmp" then
      default_return = last_instr[2] -- jmp label
   end
   table.sort(return_order, function (x, y)
                 if x.label == default_return then return true
                 elseif y.label == default_return then return false
                 else return x.value < y.value end
   end)
   for _, ret in ipairs(return_order) do
      table.insert(instructions, { "ret", ret.label, ret.value })
   end

   if verbose then
      print_selection(instructions)
   end

   return instructions
end

function selftest()
   local utils = require("pf.utils")

   -- test on a whole set of blocks
   local function test(block, expected)
      local instructions = select(block)
      utils.assert_equals(instructions, expected)
   end

   test(-- `arp`
        { start = "L1",
          order = { "L1", "L4", "L5" },
          blocks =
             { L1 = { label = "L1",
                      bindings = {},
                      control = { "if", { ">=", "len", 14}, "L4", "L5" } },
               L4 = { label = "L4",
                      bindings = {},
                      control = { "return", { "=", { "[]", 12, 2}, 1544 } } },
               L5 = { label = "L5",
                      bindings = {},
                      control = { "return", { "false" } } } } },
        { { "label", 1 },
          { "cmp", "len", 14 },
          { "cjmp", "<", "false-label"},
          { "jmp", 4 },
          { "label", 4 },
          { "load", "r1", 12, 2 },
          { "cmp", "r1", 1544 },
          { "cjmp", "=", "true-label" },
          { "jmp", "false-label" },
          { "ret", "false-label", 0 },
          { "ret", "true-label", 1 },
          max_label = 4 })

   test(-- `tcp`
        { start = "L1",
          order = { "L1", "L4", "L6", "L7", "L8", "L10", "L12", "L13",
                    "L14", "L16", "L17", "L15", "L11", "L9", "L5" },
          blocks =
             { L1 = { label = "L1",
                      bindings = {},
                      control = { "if", { ">=", "len", 34 }, "L4", "L5" } },
               L4 = { label = "L4",
                      bindings = { { name = "v1", value = { "[]", 12, 2 } } },
                      control = { "if", { "=", "v1", 8 }, "L6", "L7" },
                      idom = "L1" },
               L6 = { label = "L6",
                      bindings = {},
                      control = { "return", { "=", { "[]", 23, 1 }, 6 } },
                      idom = "L4" },
               L7 = { label = "L7",
                      bindings = {},
                      control = { "if", { ">=", "len", 54 }, "L8", "L9" },
                      idom = "L7" },
               L8 = { label = "L8",
                      bindings = {},
                      control = { "if", { "=", "v1", 56710 }, "L10", "L11" },
                      idom = "L7" },
               L10 = { label = "L10",
                       bindings = { { name = "v2", value = { "[]", 20, 1 } } },
                       control = { "if", { "=", "v2", 6 }, "L12", "L13" },
                       idom = "L9" },
               L12 = { label = "L12",
                       bindings = {},
                       control = { "return", { "true" } },
                       idom = "L10" },
	       L13 = { label = "L13",
	               bindings = {},
	               control = { "if", { ">=", "len", 55 }, "L14", "L15" } },
	       L14 = { label = "L14",
	               bindings = {},
	               control = { "if", { "=", "v2", 44 }, "L16", "L17" } },
	       L16 = { label = "L16",
	               bindings = {},
	               control = { "return", { "=", { "[]", 54, 1 }, 6 } } },
	       L17 = { label = "L17",
	               bindings = {},
	               control = { "return", { "false" } } },
	       L15 = { label = "L15",
	               bindings = {},
	               control = { "return", { "false" } } },
	       L11 = { label = "L11",
	               bindings = {},
	               control = { "return", { "false" } } },
	       L9 = { label = "L9",
	              bindings = {},
	              control = { "return", { "false" } } },
	       L5 = { label = "L5",
	              bindings = {},
	              control = { "return", { "false" } } } } },
        { { "label", 1 },
          { "cmp", "len", 34 },
          { "cjmp", "<", "false-label" },
          { "jmp", 4 },
          { "label", 4 },
          { "load", "r1", 12, 2 },
          { "mov", "v1", "r1" },
          { "cmp", "v1", 8 },
          { "cjmp", "!=", 7 },
          { "jmp", 6 },
          { "label", 6 },
          { "load", "r2", 23, 1 },
          { "cmp", "r2", 6 },
          { "cjmp", "=", "true-label" },
          { "jmp", "false-label" },
          { "label", 7 },
          { "cmp", "len", 54 },
          { "cjmp", "<", "false-label" },
          { "jmp", 8 },
          { "label", 8 },
          { "cmp", "v1", 56710 },
          { "cjmp", "!=", "false-label" },
          { "jmp", 10 },
          { "label", 10 },
          { "load", "r3", 20, 1 },
          { "mov", "v2", "r3" },
          { "cmp", "v2", 6 },
          { "cjmp", "=", "true-label" },
          { "jmp", 13 },
          { "label", 13 },
          { "cmp", "len", 55 },
          { "cjmp", "<", "false-label" },
          { "jmp", 14 },
          { "label", 14 },
          { "cmp", "v2", 44 },
          { "cjmp", "!=", "false-label" },
          { "jmp", 16 },
          { "label", 16 },
          { "load", "r4", 54, 1 },
          { "cmp", "r4", 6 },
          { "cjmp", "=", "true-label" },
          { "jmp", "false-label" },
          { "ret", "false-label", 0 },
          { "ret", "true-label", 1 },
          max_label = 16 })

   test(-- randomly generated by tests
        { start = "L1",
          order = { "L1", "L4", "L5" },
          blocks =
             { L1 = { control = { "if", { ">=", "len", 4 }, "L4", "L5" },
                      bindings = {},
                      label = "L1", },
               L4 = { control = { "return",
                                  { ">", { "ntohs", { "[]", 0, 4 } }, 0 } },
                      bindings = {},
                      label = "L4", },
               L5 = { control = { "return", { "false" } },
                      bindings = {},
                      label = "L5", } } },
        { { "label", 1 },
          { "cmp", "len", 4 },
          { "cjmp", "<", "false-label" },
          { "jmp", 4 },
          { "label", 4 },
          { "load", "r1", 0, 4 },
          { "mov", "r2", "r1" },
          { "ntohs", "r2" },
          { "cmp", "r2", 0 },
          { "cjmp", ">", "true-label" },
          { "jmp", "false-label" },
          { "ret", "false-label", 0 },
          { "ret", "true-label", 1 },
          max_label = 4 })

   test(-- calls
        { start = "L1",
          order = { "L1", "L4", "L5" },
          blocks =
             { L1 = { control = { "if", { ">=", "len", 4 }, "L4", "L5" },
                      bindings = {},
                      label = "L1", },
               L4 = { control = { "return", { "call", "foo", 1 } },
                      bindings = {},
                      label = "L4", },
               L5 = { control = { "return", { "call", "bar", 2 } },
                      bindings = {},
                      label = "L5", } } },
        { { "label", 1 },
          { "cmp", "len", 4 },
          { "cjmp", ">=", "foo" },
          { "jmp", "bar" },
          { "ret", "bar", 2 },
          { "ret", "foo", 1 },
          max_label = 1 })

   test(-- calls 2 (more elaborate)
      { start = "L1",
        order = { "L1", "L4", "L6", "L8", "L10", "L12", "L13", "L11", "L9",
                  "L7", "L14", "L15", "L5", }, 
        blocks =
           { L1 = { control = { "if", { ">=", "len", 14 }, "L4", "L5" },
                    bindings = {},
                    label = "L1", },
             L4 = { control = { "if", { "=", "v1", 8 }, "L6", "L7" },
                    bindings = { { name = "v1", value =  { "[]", 12, 2 }, } },
                    label = "L4", },
             L5 = { control = { "return", { "call", "reject_ethertype", 5 } },
                    bindings = {},
                    label = "L5", },
             L6 = { control = { "if", { ">=", "len", 34 }, "L8", "L9" },
                    bindings = {},
                    label = "L6", },
             L7 = { control =  { "if", { "=", "v1", 1544 }, "L14", "L15" },
                     bindings = {},
                     label = "L7", },
             L8 = { control = { "if", { "=", { "[]", 30, 4 }, 16777388 },
                                "L10", "L11" },
                    bindings =  {},
                    label = "L8", },
             L9 = { control = { "return", { "call", "forward4", 3 } },
                    bindings =  {},
                    label = "L9", },
             L10 = { control = { "if", { "=", { "[]", 23, 1 }, 1 }, "L12", "L13" },
                     bindings =  {},
                     label = "L10", },
             L11 = { control = { "return", { "call", "forward4", 3 } },
                     bindings = {},
                     label = "L11", },
             L12 = { control = { "return", { "call", "icmp4", 1 } },
                     bindings = {},
                     label = "L12", },
             L13 = { control =  { "return", { "call", "protocol4_unreachable", 2 } },
                     bindings = {},
                     label = "L13", },
             L14 = { control = { "return", { "call", "arp", 4 } },
                     bindings = {},
                     label = "L14", },
             L15 = { control =  { "return", { "call", "reject_ethertype", 5 } },
                     bindings =  {},
                     label = "L15", }, }, },
  {
    { "label", 1 },
    { "cmp", "len", 14 },
    { "cjmp", "<", "reject_ethertype" },
    { "jmp", 4 },
    { "label", 4 },
    { "load", "r1", 12, 2 },
    { "mov", "v1", "r1" },
    { "cmp", "v1", 8 },
    { "cjmp", "!=", 7 },
    { "jmp", 6 },
    { "label", 6 },
    { "cmp", "len", 34 },
    { "cjmp", "<", "forward4" },
    { "jmp", 8 },
    { "label", 8 },
    { "load", "r2", 30, 4 },
    { "cmp", "r2", 16777388 },
    { "cjmp", "!=", "forward4" },
    { "jmp", 10 },
    { "label", 10 },
    { "load", "r3", 23, 1 },
    { "cmp", "r3", 1 },
    { "cjmp", "=", "icmp4" },
    { "jmp", "protocol4_unreachable" },
    { "label", 7 },
    { "cmp", "v1", 1544 },
    { "cjmp", "=", "arp" },
    { "jmp", "reject_ethertype" },
    { "ret", "reject_ethertype", 5 },
    { "ret", "icmp4", 1 },
    { "ret", "protocol4_unreachable", 2 },
    { "ret", "forward4", 3 },
    { "ret", "arp", 4 },
    max_label = 10 })
end
