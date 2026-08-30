
texShader3 = dxCreateShader ( "texreplace.fx" )
headlight = dxCreateTexture("headlight.png")
dxSetShaderValue(texShader3,"gTexture",headlight)
engineApplyShaderToWorldTexture(texShader3,"headlight")
texShader4 = dxCreateShader ( "texreplace.fx" )
headlight1 = dxCreateTexture("headlight1.png")
dxSetShaderValue(texShader4,"gTexture",headlight1)
engineApplyShaderToWorldTexture(texShader4,"headlight1")
texShader6 = dxCreateShader ( "texreplace.fx" )
coronastar = dxCreateTexture("coronastar.png")
dxSetShaderValue(texShader6,"gTexture",coronastar)
engineApplyShaderToWorldTexture(texShader6,"coronastar")

