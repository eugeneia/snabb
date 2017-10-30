-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

-- “XSD types” regular expression implementation (ASCII only), see:
-- https://www.w3.org/TR/xmlschema11-2/#regexs
module(..., package.seeall)

local maxpc = require("lib.maxpc")
local match, capture, combine = maxpc.import()

function capture.token (x)
   return capture.subseq(match.equal(x))
end

function capture.regExp ()
   return capture.unpack(
      capture.seq(capture.branch(),
                  combine.any(capture.otherBranch())),
      function (branch, otherBranches)
         local branches = {branch}
         for _, branch in ipairs(otherBranches or {}) do
            table.insert(branches, branch)
         end
         return branches
      end
   )
end

function capture.branch ()
   return combine.any(capture.piece())
end

function capture.otherBranch ()
   return capture.unpack(
      capture.seq(match.equal("|"), capture.branch()),
      function (_, branch)
         return branch
      end
   )
end

function capture.piece ()
   return capture.seq(capture.atom(), combine.maybe(capture.quantifier()))
end

function capture.quantifier ()
   return combine._or(
      capture.token("?"),
      capture.token("*"),
      capture.token("+"),
      capture.unpack(capture.seq(match.equal("{"),
                                 capture.quanitity,
                                 match.equal("}")),
                     function (_, quantity, _) return quanitity end)
   )
end

function match.digit (s)
   return match.satisfies(
      function (s)
         return ("0123456789"):find(s, 1, true)
      end
   )
end

function capture.quantity ()
   return capture.seq(
      capture.quantExact(),
      combine.maybe(capture.quantMax())
   )
end

function capture.quantExact ()
   return capture.transform(
      capture.subseq(combine.some(match.digit())),
      tonumber
   )
end

function capture.quantMax ()
   return capture.unpack(
      capture.seq(match.equal(","), capture.quantExact()),
      function (_, max) return max end
   )
end

function capture.atom ()
   return combine._or(
      capture.NormalChar(),
      capture.charClass(),
      capture.subExp()
   )
end

local regExp_parser -- forward definition

function capture.subExp ()
   return capture.unpack(
      capture.seq(match.equal('('), regExp_parser, match.equal(')')),
      function (_, expression, _) return expression end
   )
end

function match.MetaChar ()
   return match.satisfies(
      function (s)
         return (".\\?*+{}()|[]"):find(s, 1, true)
      end
   )
end

function match.NormalChar (s)
   return match._not(match.MetaChar())
end

function capture.NormalChar ()
   return capture.subseq(match.NormalChar())
end

function capture.charClass ()
   return combine._or(
      capture.SingleCharEsc(),
      capture.charClassEsc(),
      capture.charClassExpr(),
      capture.WildcardEsc()
   )
end

function capture.charClassExpr ()
   return capture.unpack(
      capture.seq(match.equal("["), capture.charGroup(), match.equal("]")),
      function (_, charGroup, _) return charGroup end
   )
end

local charClassExpr_parser -- forward declaration

function capture.charGroup ()
   local subtract = capture.unpack(
      capture.seq(match.equal("-"), charClassExpr_parser),
      function (_, charClassExpr, _) return charClassExpr end
   )
   return capture.seq(
      combine._or(capture.posCharGroup(), capture.negCharGroup()),
      combine.maybe(subtract)
   )
end

function capture.posCharGroup ()
   return combine.some(capture.charGroupPart())
end

function capture.negCharGroup ()
   return capture.seq(capture.token("^"), capture.posCharGroup())
end

function capture.charGroupPart ()
   return combine._or(
      capture.singleChar(), capture.charRange(), capture.charClassEsc()
   )
end

function capture.singleChar ()
   return combine._or(capture.SingleCharEsc(), capture.singleCharNoEsc())
end

function capture.charRange ()
   return capture.seq(
      capture.singleChar(), match.equal("-"), capture.singleChar()
   )
end

function capture.singleCharNoEsc ()
   local function is_singleCharNoEsc (s)
      return not ("[]"):find(s, 1, true)
   end
   return capture.subseq(match.satisfies(is_singleCharNoEsc))
end

function capture.charClassEsc ()
   return combine._or(
      capture.MultiCharEsc() --, capture.catEsc(), capture.complEsc()
   )
end

function capture.SingleCharEsc ()
   local function is_SingleCharEsc (s)
      return ("nrt\\|.?*+(){}-[]^"):find(s, 1, true)
   end
   return capture.seq(
      capture.token("\\"),
      capture.subseq(match.satisfies(is_SingleCharEsc))
   )
end

-- NYI: catEsc, complEsc

function capture.MultiCharEsc ()
   local function is_multiCharEsc (s)
      return ("sSiIcCdDwW"):find(s, 1, true)
   end
   return capture.seq(
      capture.token("\\"),
      capture.subseq(match.satisfies(is_multiCharEsc))
   )
end

function capture.WildcardEsc ()
   return capture.token(".")
end

regExp_parser = capture.regExp()
charClassExpr_parser = capture.charClassExpr()

function parse (expr)
   return maxpc.parse(expr, regExp_parser)
end
