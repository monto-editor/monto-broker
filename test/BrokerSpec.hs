{-# LANGUAGE CPP, OverloadedStrings #-}
module BrokerSpec(spec) where

import           Control.Monad.State
import           Control.Arrow

import qualified Data.Vector as V
import qualified Data.Map as M
import qualified Data.Set as S

import           Monto.Broker (Response(..))
import qualified Monto.Broker as B
import qualified Monto.VersionMessage as V
import qualified Monto.ProductMessage as P
import qualified Monto.ProductDescription as PD
import           Monto.ProductDependency
import           Monto.Types
import           Monto.RegisterServiceRequest
import           Monto.ServiceDependency

import           Test.Hspec


spec :: Spec
spec = do

  let register sid lang deps = B.registerService (RegisterServiceRequest sid "" "" lang Nothing (V.fromList deps))
      java = "java" :: Language
      tokens = "tokens" :: Product
      ast = "ast" :: Product
      completions = "completions" :: Product
      errors = "errors" :: Product
      javaTypechecker = "javaTypechecker" :: ServiceID
      javaCodeCompletion = "javaCodeCompletion" :: ServiceID
      javaParser = "javaParser" :: ServiceID
      javaTokenizer = "javaTokenizer" :: ServiceID
      javaSource = SourceDependency java
      s1 i = V.VersionMessage i "s1" "java" "" Nothing
      s2 i = V.VersionMessage i "s2" "java" "" Nothing
      astMsg vid src deps = P.ProductMessage vid src javaParser ast java "" (V.fromList deps)
      typMsg vid src deps = P.ProductMessage vid src javaTypechecker errors java "" (V.fromList deps)
      comMsg vid src deps = P.ProductMessage vid src javaCodeCompletion completions java "" (V.fromList deps)
      tokMsg vid src deps = P.ProductMessage vid src javaTokenizer tokens java "" (V.fromList deps)
      v1 = VersionID 1
      newVersion' v b = first S.fromList $ B.newVersion v b
      newProduct' v b = first S.fromList $ B.newProduct v b

  context  "Static Dependencies" $ do

    let broker = register javaCodeCompletion java [PD.ProductDescription completions [javaSource, ServiceDependency javaParser ast java]]
               $ register javaTypechecker java [PD.ProductDescription errors [javaSource, ServiceDependency javaParser ast java]]
               $ register javaParser java [PD.ProductDescription ast [javaSource]]
               $ register javaTokenizer java [PD.ProductDescription tokens [javaSource]]
               $ B.empty (Port 5010) (Port 5020)
        javaTokenizerService = B.services broker M.! javaTokenizer
        javaParserService = B.services broker M.! javaParser
        javaCodeCompletionService = B.services broker M.! javaCodeCompletion
        javaTypecheckerService = B.services broker M.! javaTypechecker

    it "can manage static server dependencies" $
      void $ flip execStateT broker $ do

        newVersion' (s1 v1) `shouldBe'` S.fromList
           [ Response "s1" javaParserService [B.VersionMessage (s1 v1)]
           , Response "s1" javaTokenizerService [B.VersionMessage (s1 v1)]
           ]

        let ast1 = astMsg v1 "s1" []
        newProduct' ast1 `shouldBe'` S.fromList
           [ Response "s1" javaCodeCompletionService [B.VersionMessage (s1 v1), B.ProductMessage ast1]
           , Response "s1" javaTypecheckerService [B.VersionMessage (s1 v1), B.ProductMessage ast1]
           ]

        newProduct' (tokMsg v1 "s1" []) `shouldBe'` S.fromList []
        newProduct' (comMsg v1 "s1" []) `shouldBe'` S.fromList []
        newProduct' (typMsg v1 "s1" []) `shouldBe'` S.fromList []

    it "can deal with outdated products" $ do
      _ <- flip execStateT broker $ do
        let currentId = VersionID 42
            outdatedId = VersionID 41

        newVersion' (s1 currentId) `shouldBe'` S.fromList
           [ Response "s1" javaParserService [B.VersionMessage (s1 currentId)]
           , Response "s1" javaTokenizerService [B.VersionMessage (s1 currentId)]
           ]

        -- outdated product arrives
        newProduct' (astMsg outdatedId "s1" []) `shouldBe'` S.fromList []

      return ()


  context "Product Dependencies" $ do

    let broker = register javaTypechecker java [PD.ProductDescription errors [javaSource,ServiceDependency javaParser ast java]]
               $ register javaParser java [PD.ProductDescription ast [javaSource]]
               $ B.empty (Port 5010) (Port 5020)
        javaParserService = B.services broker M.! javaParser
        javaTypecheckerService = B.services broker M.! javaTypechecker

    it "can track dynamic product dependencies" $
      --
      --     s1      s2      s3
      --     ^       ^       ^
      --    ast     ast     ast
      --     ^       ^       ^
      --   type <- type <- type
      --
      void $ flip execStateT broker $ do
        B.registerProductDependency
             (ProductDependency "s2" javaTypechecker errors java)
             [ProductDependency "s1" javaTypechecker errors java] `shouldBe'`
          ["s1"]

        B.registerProductDependency
             (ProductDependency "s3" javaTypechecker errors java)
             [ProductDependency "s2" javaTypechecker errors java] `shouldBe'`
          ["s2"]

        B.newVersion (s1 v1) `shouldBe'`
          [Response "s1" javaParserService [B.VersionMessage (s1 v1)]]

        let ast1s1 = astMsg v1 "s1" []
            ast1s2 = astMsg v1 "s2" []
            typ1s1 = typMsg v1 "s1" []

        B.newProduct ast1s1 `shouldBe'`
          [Response "s1" javaTypecheckerService [B.ProductMessage ast1s1]]

        B.newVersion (s2 v1) `shouldBe'`
          [Response "s2" javaParserService [B.VersionMessage (s2 v1)]]

        B.newProduct ast1s2 `shouldBe'` []

        B.newProduct typ1s1 `shouldBe'`
          [Response "s2" javaTypecheckerService [B.ProductMessage ast1s2,B.ProductMessage typ1s1]]

  where
    shouldBe' actual expected = do
      act <- state actual
      lift $ act `shouldBe` expected
